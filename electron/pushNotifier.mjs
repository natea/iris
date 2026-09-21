// What the Mac tells a paired phone when it cannot ask it directly: a run it
// dispatched has finished, or a run it dispatched is stuck waiting on a human.
// Nothing else, and never a result body — a lock screen shows notifications,
// and the phone can fetch the result over Link once it is opened.

export const COMPLETION_PUSH_GRACE_MS = 6_000;
const MAX_BODY_CHARS = 110;
const MAX_ATTENTION_KEYS = 200;

export function deviceIdFromOrigin(origin) {
  const value = String(origin || "");
  return value.startsWith("device:") ? value.slice("device:".length) : "";
}

// The title is the REAL terminal status, never an optimistic default.
export function completionTitle(status) {
  const value = String(status || "").trim().toLowerCase();
  if (value === "completed") return "Hermes finished";
  if (value === "cancelled" || value === "canceled") return "Hermes was stopped";
  return "Hermes couldn't finish";
}

export function shortenForPush(text, max = MAX_BODY_CHARS) {
  const cleaned = String(text || "")
    .replace(/\s+/g, " ")
    .trim();
  if (!cleaned) return "";
  if (cleaned.length <= max) return cleaned;
  return `${cleaned.slice(0, max - 1).trimEnd()}…`;
}

/**
 * @param failure  The classified `{ code, message, recovery }` for a failed
 *                 run, or null. Its `message` is one plain sentence built by
 *                 hermesFailure.mjs: it carries no result text and no secret,
 *                 which is why it is allowed on a lock screen when the raw
 *                 error never would be.
 */
export function buildCompletionPayload({ runId, task, status, failure = null }) {
  const reason = failure?.message ? shortenForPush(failure.message) : "";
  return {
    aps: {
      alert: {
        title: completionTitle(status),
        // A failed run leads with WHY. "Hermes couldn't finish" over a task
        // title tells the user nothing they can act on; the reason does.
        // Otherwise the task title only — no output, no error text, no result.
        body: reason || shortenForPush(task) || "A task you sent from this phone.",
      },
      sound: "default",
      "thread-id": String(runId),
      "interruption-level": "active",
    },
    run_id: String(runId),
    kind: "run_complete",
    // So the phone can open straight onto the failure card with the right
    // recovery offered, without a round trip first.
    ...(failure?.code ? { failure_code: String(failure.code) } : {}),
    ...(failure?.recovery ? { recovery: String(failure.recovery) } : {}),
  };
}

export function buildAttentionPayload({ runId, task, requestId, canApproveFromPhone }) {
  const where = canApproveFromPhone
    ? "Open Iris to approve or deny it."
    : "It needs an answer on the Mac.";
  const summary = shortenForPush(task, MAX_BODY_CHARS - where.length - 3);
  return {
    aps: {
      alert: {
        title: "Hermes needs you",
        body: summary ? `${summary} — ${where}` : where,
      },
      sound: "default",
      "thread-id": String(runId),
      // Waiting on a human is exactly what time-sensitive is for: it breaks
      // through Focus, a completion does not.
      "interruption-level": "time-sensitive",
    },
    run_id: String(runId),
    kind: "needs_attention",
    request_id: String(requestId || ""),
    can_approve_from_phone: Boolean(canApproveFromPhone),
  };
}

/**
 * @param getClient     () => apnsClient | null — null means push is unconfigured.
 * @param getTarget     (deviceId) => { token, environment } | null
 * @param isAnnounced   (runId) => boolean — the phone already spoke this result.
 * @param dropToken     (deviceId) => void — Apple says the token is dead.
 */
export function createPushNotifier({
  getClient = () => null,
  getTarget = () => null,
  isAnnounced = () => false,
  dropToken = () => {},
  log = () => {},
  graceMs = COMPLETION_PUSH_GRACE_MS,
  schedule = (fn, ms) => setTimeout(fn, ms),
  clear = (handle) => clearTimeout(handle),
} = {}) {
  const pendingCompletions = new Map();
  const sentAttention = new Set();
  let unconfiguredLogged = false;

  const safeLog = (message, level = "info") => {
    try {
      log(message, level);
    } catch {
      // Logging must never fail a push.
    }
  };

  function client() {
    const value = getClient();
    if (!value && !unconfiguredLogged) {
      unconfiguredLogged = true;
      safeLog("Push notifications are not configured, so Iris will not push to paired phones.");
    }
    return value;
  }

  async function deliver({ deviceId, payload, collapseId, priority }) {
    const apns = client();
    if (!apns) return { skipped: "not_configured" };
    const target = getTarget(deviceId);
    if (!target?.token) return { skipped: "no_token" };
    const result = await apns.send({
      deviceToken: target.token,
      environment: target.environment,
      payload,
      collapseId,
      priority,
    });
    if (result?.unregistered) {
      // Apple says this token is dead. Forget it rather than push to it again.
      try {
        dropToken(deviceId);
      } catch {
        // A failed cleanup must not fail the send path.
      }
      safeLog("A paired phone's push token was rejected by Apple and has been removed.", "warn");
    }
    return { sent: true, result };
  }

  return {
    /**
     * A run reached a terminal state. Only device-origin runs push, only to the
     * device that dispatched them, and only after a short grace window: if the
     * phone is in a live session it announces the result itself and acks with
     * POST /link/tasks/:id/announced, which wins the race and cancels this.
     */
    notifyRunTerminal({ runId, task, status, origin, failure = null }) {
      const deviceId = deviceIdFromOrigin(origin);
      if (!runId || !deviceId) return Promise.resolve({ skipped: "not_device_origin" });
      const existing = pendingCompletions.get(runId);
      if (existing) clear(existing.handle);
      return new Promise((resolve) => {
        const handle = schedule(() => {
          pendingCompletions.delete(runId);
          if (isAnnounced(runId)) {
            resolve({ skipped: "announced" });
            return;
          }
          deliver({
            deviceId,
            payload: buildCompletionPayload({ runId, task, status, failure }),
            collapseId: String(runId).slice(0, 64),
            priority: 10,
          }).then(resolve, () => resolve({ skipped: "error" }));
        }, graceMs);
        handle?.unref?.();
        pendingCompletions.set(runId, { handle, resolve });
      });
    },

    /**
     * A device-origin run is waiting on the user. At most one push per distinct
     * pending request, whether it was seen once over SSE or ten times by poll.
     */
    notifyNeedsAttention({ runId, task, origin, requestId, canApproveFromPhone = false }) {
      const deviceId = deviceIdFromOrigin(origin);
      if (!runId || !deviceId || !requestId) {
        return Promise.resolve({ skipped: "not_device_origin" });
      }
      const key = `${runId}::${requestId}`;
      if (sentAttention.has(key)) return Promise.resolve({ skipped: "duplicate" });
      sentAttention.add(key);
      if (sentAttention.size > MAX_ATTENTION_KEYS) {
        const oldest = sentAttention.values().next().value;
        sentAttention.delete(oldest);
      }
      return deliver({
        deviceId,
        payload: buildAttentionPayload({ runId, task, requestId, canApproveFromPhone }),
        collapseId: key.slice(0, 64),
        priority: 10,
      }).catch(() => ({ skipped: "error" }));
    },

    // The request was answered (or the run ended): the next distinct request
    // for this run is allowed to push again.
    clearAttention(runId) {
      const prefix = `${runId}::`;
      for (const key of sentAttention) {
        if (key.startsWith(prefix)) sentAttention.delete(key);
      }
    },

    cancelCompletion(runId) {
      const existing = pendingCompletions.get(runId);
      if (!existing) return false;
      clear(existing.handle);
      pendingCompletions.delete(runId);
      existing.resolve({ skipped: "cancelled" });
      return true;
    },
  };
}
