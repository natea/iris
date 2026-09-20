// The Live Activity half of "a live widget on the home screen so you can
// monitor what Hermes is doing in the background."
//
// A Live Activity can only change while the app is suspended if an ActivityKit
// push arrives, so this module decides WHEN the Mac pushes and WHAT it says.
// It is pure in the same way pushNotifier.mjs is: the APNs client, the token
// store, the clock and the timer are all injected, so every rule below is
// testable without a network, without Electron and without a phone.
//
// ONE SUMMARY ACTIVITY PER DEVICE.
// ---------------------------------
// The phone runs a single "Hermes" activity that shows the most relevant
// active run plus a short list of the others, not one activity per run. The
// user asked to monitor what Hermes is doing, which is a single ongoing
// answer; iOS caps how many activities an app may run at once and picks ONE
// for the Dynamic Island anyway; and one activity means one push-to-start
// token, one update token and one coalescing window, which is what keeps the
// Mac inside Apple's per-hour budget when Hermes emits ten events a second.
// The trade-off is detail: a summary line cannot show a run's whole step list.
// It does not have to — the phone already has `GET /link/tasks/:id` (§12) for
// that, and the activity's job is to be glanceable and true.
//
// TRUTHFULNESS. Hermes reports no percentages, so neither does this: there is
// no progress bar and no ETA anywhere in the state. Only the real headline,
// the real step count, the real status. When Iris was restarted mid-run the
// steps are simply gone, and the state says `stepsKnown: false` rather than
// claiming zero work happened.

import { TERMINAL_STATUSES } from "./runSteps.mjs";

// How often, at most, one device's activity is updated. Apple throttles
// ActivityKit pushes against an hourly budget; 8 s is slow enough to stay
// inside it over a long run and fast enough that a tool change shows up while
// the user is still looking at the phone.
export const LIVE_ACTIVITY_MIN_INTERVAL_MS = 8_000;
// Sent as `stale-date` on every non-terminal push. If the Mac sleeps, loses
// Tailscale or is quit, the activity crosses into `.stale` at this point and
// the phone says "Iris hasn't checked in" instead of implying Hermes is still
// working. Comfortably longer than the coalescing window so ordinary
// throttling never makes a live activity look dead.
export const LIVE_ACTIVITY_STALE_MS = 120_000;
// How long a finished activity stays on the Lock Screen. A happy ending is
// glanceable for a few minutes; a failure or a stop is something the user may
// well have missed, so it lingers.
export const DISMISSAL_COMPLETED_MS = 5 * 60_000;
export const DISMISSAL_UNHAPPY_MS = 30 * 60_000;
// After a push-to-start, the phone needs a moment to be woken, start the
// activity and PUT its update token back. Do not push-to-start again inside
// this window or one busy minute becomes several duplicate activities.
export const PUSH_TO_START_GRACE_MS = 60_000;

// Must match the Swift `ActivityAttributes` type name exactly; Apple matches
// `attributes-type` against it by name.
export const LIVE_ACTIVITY_ATTRIBUTES_TYPE = "IrisRunActivityAttributes";

// The payload cap is 4096 bytes (Apple). Build to a lower ceiling and shed
// optional detail until it fits, so an unusually long task title can never
// cost the user an update.
export const LIVE_ACTIVITY_PAYLOAD_BUDGET = 3_200;

export const MAX_SUMMARY_RUNS = 3;
const MAX_TITLE_CHARS = 80;
const MAX_HEADLINE_CHARS = 80;
const MAX_DETAIL_CHARS = 100;
const MAX_ATTENTION_CHARS = 100;

export const LIVE_ACTIVITY_STATUSES = Object.freeze([
  "running",
  "waiting",
  "idle",
  "done",
  "failed",
  "stopped",
]);

function clamp(text, max) {
  const cleaned = String(text || "")
    .replace(/\s+/g, " ")
    .trim();
  if (!cleaned) return "";
  return cleaned.length <= max ? cleaned : `${cleaned.slice(0, max - 1).trimEnd()}…`;
}

function isTerminal(status) {
  return TERMINAL_STATUSES.has(String(status || "").trim().toLowerCase());
}

/** The real terminal status, mapped to the six words the activity may show. */
export function terminalContentStatus(status) {
  const value = String(status || "").trim().toLowerCase();
  if (value === "completed") return "done";
  if (value === "cancelled" || value === "canceled") return "stopped";
  if (value === "failed" || value === "error") return "failed";
  return "idle";
}

// Epoch SECONDS as a Double, never an encoded `Date`. Apple: "don't use any
// custom JSON encoding strategies … the system always decodes JSON payloads
// for Live Activity updates using its default encoding strategies." A default
// `JSONDecoder` reads `Date` as seconds since the 2001 reference date, which
// is a trap nobody notices until the activity shows 1970. A `Double` the Swift
// side feeds to `Date(timeIntervalSince1970:)` cannot be misread.
function epochSeconds(millis) {
  const value = Number(millis);
  if (!Number.isFinite(value) || value <= 0) return 0;
  return Math.round(value / 1000);
}

function runLine(run) {
  return {
    id: String(run?.runId || "").slice(0, 64),
    title: clamp(run?.title, MAX_TITLE_CHARS),
    status: isTerminal(run?.status)
      ? terminalContentStatus(run?.status)
      : run?.pendingApproval
        ? "waiting"
        : "running",
    headline: clamp(run?.headline, MAX_HEADLINE_CHARS),
  };
}

/**
 * The single source of truth for the Live Activity's `ContentState`. The Swift
 * `ContentState` must decode EXACTLY this — same key names, same casing, same
 * types, every field present. See LINK_API.md §14.
 *
 * @param snapshot {{activeRuns: object[], lastFinished: object|null}}
 */
export function buildContentState(snapshot, { at = Date.now() } = {}) {
  const active = (Array.isArray(snapshot?.activeRuns) ? snapshot.activeRuns : []).filter(
    (run) => run && run.runId && !isTerminal(run.status),
  );
  const waiting = active.filter((run) => run.pendingApproval);
  // A run that is blocked on a human is what the user most needs to see;
  // otherwise the one that moved most recently.
  const primary =
    waiting[0] ||
    [...active].sort((a, b) => (Number(b?.updatedAt) || 0) - (Number(a?.updatedAt) || 0))[0] ||
    null;
  const finished = snapshot?.lastFinished || null;

  let status;
  if (waiting.length) status = "waiting";
  else if (active.length) status = "running";
  else if (finished) status = terminalContentStatus(finished.status);
  else status = "idle";

  const stepsKnown = primary ? primary.stepsKnown !== false : false;
  return {
    status,
    // Empty rather than invented. The phone shows the status when this is "".
    headline: primary ? clamp(primary.headline, MAX_HEADLINE_CHARS) : "",
    title: clamp(primary ? primary.title : finished?.title, MAX_TITLE_CHARS),
    detail: primary ? clamp(primary.detail, MAX_DETAIL_CHARS) : "",
    stepCount: primary && stepsKnown ? Math.max(0, Math.round(Number(primary.stepCount) || 0)) : 0,
    // False after an Iris restart, or before any event has been recorded: the
    // phone must say "step history unavailable", never "0 steps".
    stepsKnown,
    activeRunCount: active.length,
    needsAttention: waiting.length > 0,
    attentionSummary: clamp(waiting[0]?.pendingApproval?.summary, MAX_ATTENTION_CHARS),
    runs: active.slice(0, MAX_SUMMARY_RUNS).map(runLine),
    startedAt: epochSeconds(primary ? primary.startedAt : finished?.startedAt),
    updatedAt: epochSeconds(at),
  };
}

/**
 * Everything that makes a push worth spending, with the clock excluded: two
 * states with the same signature say the same thing, so the second one is not
 * sent. This is what turns Hermes' event firehose into a handful of pushes.
 */
export function contentSignature(state) {
  const { updatedAt, ...rest } = state || {};
  try {
    return JSON.stringify(rest);
  } catch {
    return String(Date.now());
  }
}

function sizeOf(payload) {
  try {
    return Buffer.byteLength(JSON.stringify(payload), "utf8");
  } catch {
    return Number.MAX_SAFE_INTEGER;
  }
}

/**
 * Shed optional detail until the payload fits Apple's limit: the run list
 * first (the phone can fetch it), then the free-text fields. The primary run's
 * status, headline and counts are never dropped — they are the point.
 */
export function fitPayload(payload, { budget = LIVE_ACTIVITY_PAYLOAD_BUDGET } = {}) {
  let current = payload;
  if (sizeOf(current) <= budget) return current;
  const state = current?.aps?.["content-state"];
  if (!state) return current;
  const shrink = [
    () => {
      state.runs = state.runs.slice(0, 1);
    },
    () => {
      state.runs = [];
    },
    () => {
      state.detail = "";
    },
    () => {
      state.attentionSummary = clamp(state.attentionSummary, 40);
    },
    () => {
      state.title = clamp(state.title, 40);
      state.headline = clamp(state.headline, 40);
    },
  ];
  for (const step of shrink) {
    step();
    if (sizeOf(current) <= budget) return current;
  }
  return current;
}

function staleDate(at) {
  return epochSeconds(at + LIVE_ACTIVITY_STALE_MS);
}

export function buildUpdatePayload({ state, at = Date.now(), alert = null } = {}) {
  const aps = {
    timestamp: epochSeconds(at),
    event: "update",
    "content-state": state,
    // Advanced on every push: a Mac that stops pushing leaves an activity that
    // visibly goes stale instead of lying that work continues.
    "stale-date": staleDate(at),
    // One activity per device, but a relative score still tells the system
    // which of OUR activities to show if a stale one lingers.
    "relevance-score": state?.needsAttention ? 100 : 50,
  };
  if (alert) aps.alert = alert;
  return fitPayload({ aps });
}

export function buildStartPayload({ state, attributes, at = Date.now(), alert } = {}) {
  return fitPayload({
    aps: {
      timestamp: epochSeconds(at),
      event: "start",
      "content-state": state,
      "attributes-type": LIVE_ACTIVITY_ATTRIBUTES_TYPE,
      attributes,
      "stale-date": staleDate(at),
      "relevance-score": 100,
      // iOS 18+: ask the system for a fresh update token for the activity it
      // is about to start. Older systems ignore the key and deliver the token
      // through `pushTokenUpdates` anyway.
      "input-push-token": 1,
      // Apple requires an alert on a start payload, so a Live Activity never
      // appears without the person being told.
      alert: alert || {
        title: "Hermes is working",
        body: clamp(state?.title, MAX_TITLE_CHARS) || "A task you sent from this phone.",
        sound: "default",
      },
    },
  });
}

export function buildEndPayload({ state, at = Date.now(), dismissAfterMs } = {}) {
  const unhappy = state?.status === "failed" || state?.status === "stopped";
  const linger = Number.isFinite(dismissAfterMs)
    ? dismissAfterMs
    : unhappy
      ? DISMISSAL_UNHAPPY_MS
      : DISMISSAL_COMPLETED_MS;
  return fitPayload({
    aps: {
      timestamp: epochSeconds(at),
      event: "end",
      // Apple: "If you end a Live Activity, include the final content state to
      // make sure the Live Activity displays the latest data after it ends."
      "content-state": state,
      "dismissal-date": epochSeconds(at + linger),
    },
  });
}

/**
 * @param getClient      () => apnsClient | null — null means push is unconfigured.
 * @param getSnapshot    () => {activeRuns, lastFinished} — real run state, never a guess.
 * @param getDeviceIds   () => string[] — devices holding a Live Activity token.
 * @param getTargets     (deviceId) => {startToken, activities} | null
 * @param getAttributes  (deviceId) => object — static, set once at start.
 * @param dropActivity   (deviceId, activityId) => void — Apple says it is dead.
 * @param dropStartToken (deviceId) => void
 */
export function createLiveActivityNotifier({
  getClient = () => null,
  getSnapshot = () => ({ activeRuns: [], lastFinished: null }),
  getDeviceIds = () => [],
  getTargets = () => null,
  getAttributes = () => ({}),
  dropActivity = () => {},
  dropStartToken = () => {},
  log = () => {},
  now = () => Date.now(),
  intervalMs = LIVE_ACTIVITY_MIN_INTERVAL_MS,
  schedule = (fn, ms) => setTimeout(fn, ms),
  clear = (handle) => clearTimeout(handle),
} = {}) {
  let lastSignature = "";
  let lastPushAt = 0;
  let timer = null;
  let lastActiveCount = 0;
  let lastNeedsAttention = false;
  let unconfiguredLogged = false;
  /** deviceId -> when a push-to-start was last sent. */
  const startedAt = new Map();
  /** Resolves after the current in-flight fan-out; tests await it. */
  let inFlight = Promise.resolve();

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
      safeLog("Push is not configured, so Iris will not drive a Live Activity on any phone.");
    }
    return value;
  }

  function snapshot() {
    try {
      const value = getSnapshot();
      return {
        activeRuns: Array.isArray(value?.activeRuns) ? value.activeRuns : [],
        lastFinished: value?.lastFinished || null,
      };
    } catch {
      return { activeRuns: [], lastFinished: null };
    }
  }

  async function sendTo({ deviceId, target, payload, priority, pushType = "liveactivity" }) {
    const apns = client();
    if (!apns) return { skipped: "not_configured" };
    const result = await apns.send({
      deviceToken: target.token,
      environment: target.environment,
      payload,
      priority,
      pushType,
    });
    if (result?.unregistered) {
      try {
        if (target.activityId) dropActivity(deviceId, target.activityId);
        else dropStartToken(deviceId);
      } catch {
        // A failed cleanup must not fail the send path.
      }
      safeLog("A phone's Live Activity token was rejected by Apple and has been removed.", "warn");
    }
    return { sent: true, result };
  }

  // One fan-out: the same state to every device that is showing it.
  async function broadcast({ event, state, priority, alert, at }) {
    const results = [];
    let deviceIds;
    try {
      deviceIds = getDeviceIds() || [];
    } catch {
      deviceIds = [];
    }
    for (const deviceId of deviceIds) {
      const targets = getTargets(deviceId);
      if (!targets?.activities?.length) continue;
      const payload =
        event === "end"
          ? buildEndPayload({ state, at })
          : buildUpdatePayload({ state, at, alert });
      for (const activity of targets.activities) {
        results.push(
          await sendTo({
            deviceId,
            target: { ...activity, activityId: activity.activityId },
            payload,
            priority,
          }),
        );
        if (event === "end") {
          // The activity is over; its update token can never be used again.
          try {
            dropActivity(deviceId, activity.activityId);
          } catch {
            // Best effort.
          }
          startedAt.delete(deviceId);
        }
      }
    }
    return results;
  }

  function cancelTimer() {
    if (!timer) return;
    clear(timer);
    timer = null;
  }

  function push({ force = false } = {}) {
    const at = now();
    const state = buildContentState(snapshot(), { at });
    const signature = contentSignature(state);
    const ending = state.activeRunCount === 0 && lastActiveCount > 0;
    const attentionAppeared = state.needsAttention && !lastNeedsAttention;

    if (!force && !ending && signature === lastSignature) return inFlight;
    // Nothing is running and this is not the moment the last run stopped:
    // there is nothing to monitor, and the `end` push already delivered the
    // final word. Remember the state so the next real change still pushes.
    if (!ending && state.activeRunCount === 0) {
      lastSignature = signature;
      lastActiveCount = 0;
      lastNeedsAttention = false;
      cancelTimer();
      return inFlight;
    }

    lastSignature = signature;
    lastPushAt = at;
    lastActiveCount = state.activeRunCount;
    lastNeedsAttention = state.needsAttention;
    cancelTimer();

    if (!client()) return inFlight;

    // Priority 5 is the budget-free one and is the default for routine
    // progress. Priority 10 is spent only on the two things a person actually
    // needs at once: "Hermes is blocked on you" and "it is finished".
    const priority = ending || attentionAppeared ? 10 : 5;
    const alert =
      attentionAppeared && state.attentionSummary
        ? {
            title: "Hermes needs you",
            body: state.attentionSummary,
            sound: "default",
          }
        : null;

    inFlight = broadcast({
      event: ending ? "end" : "update",
      state,
      priority,
      alert,
      at,
    }).catch(() => []);
    return inFlight;
  }

  return {
    /**
     * Something changed in run state. Cheap, synchronous, and safe to call
     * from the middle of the event path: it either pushes now or arms a
     * trailing flush so the final state always lands.
     */
    noteChange() {
      const at = now();
      const state = buildContentState(snapshot(), { at });
      const ending = state.activeRunCount === 0 && lastActiveCount > 0;
      const attentionAppeared = state.needsAttention && !lastNeedsAttention;
      if (contentSignature(state) === lastSignature && !ending) return;
      // A run ending, or a human being asked for something, is not made to
      // wait out a coalescing window.
      if (ending || attentionAppeared || at - lastPushAt >= intervalMs) {
        push();
        return;
      }
      if (timer) return;
      const wait = Math.max(0, intervalMs - (at - lastPushAt));
      timer = schedule(() => {
        timer = null;
        push();
      }, wait);
      timer?.unref?.();
    },

    /**
     * A run this device dispatched has started. If the device has a
     * push-to-start token and no activity yet, start one remotely; otherwise
     * the app starts it locally while it is foregrounded and just registers
     * its update token.
     */
    async noteDeviceRunStarted({ deviceId } = {}) {
      const id = String(deviceId || "");
      if (!id) return { skipped: "no_device" };
      const apns = client();
      if (!apns) return { skipped: "not_configured" };
      const targets = getTargets(id);
      if (!targets?.startToken) return { skipped: "no_start_token" };
      // Already showing one: an update will carry the new run.
      if (targets.activities?.length) return { skipped: "already_live" };
      const at = now();
      const last = startedAt.get(id) || 0;
      if (at - last < PUSH_TO_START_GRACE_MS) return { skipped: "start_pending" };
      startedAt.set(id, at);
      const state = buildContentState(snapshot(), { at });
      lastSignature = contentSignature(state);
      lastPushAt = at;
      lastActiveCount = state.activeRunCount;
      lastNeedsAttention = state.needsAttention;
      const payload = buildStartPayload({
        state,
        attributes: getAttributes(id) || {},
        at,
      });
      // A start is the one push the person has not seen anything about yet.
      return sendTo({
        deviceId: id,
        target: { ...targets.startToken, activityId: "" },
        payload,
        priority: 10,
      });
    },

    /** Push the current state now, ignoring the coalescing window. */
    flush() {
      cancelTimer();
      return push({ force: true });
    },

    /** Test/diagnostic surface: resolves once the current fan-out is done. */
    settled() {
      return inFlight;
    },

    stop() {
      cancelTimer();
    },
  };
}
