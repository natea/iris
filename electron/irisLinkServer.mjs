import http from "node:http";

// Iris Link is a network-reachable door to a terminal-capable agent, so every
// default here is the restrictive one: no CORS, no cache, a tiny body cap, an
// explicit route allowlist, and Hermes' shared key attached server-side only.
export const MAX_BODY_BYTES = 64 * 1024;
export const PAIR_RATE_LIMIT = { windowMs: 60_000, max: 10 };
const UPSTREAM_TIMEOUT_MS = 30_000;
const HEADERS_TIMEOUT_MS = 20_000;
const REQUEST_TIMEOUT_MS = 60_000;
// /link/status used to relay a cached reachability flag that could be minutes
// stale, which showed "agent unreachable" on a phone while Hermes was fine.
// Fresh enough to be true, cheap enough that a polling phone cannot turn it
// into a probe storm.
export const HERMES_STATUS_CACHE_MS = 5_000;
export const HERMES_STATUS_TIMEOUT_MS = 2_500;
export const MAX_TASK_CHARS = 20_000;
export const TASK_URGENCIES = Object.freeze(["low", "normal", "high"]);
export const APPROVAL_DECISIONS = Object.freeze(["once", "session", "always", "deny"]);
export const GEMINI_TOKEN_PURPOSES = Object.freeze(["session", "preview"]);

// Handler failures are named, not improvised: the phone branches on these and
// the contract document lists every one.
const TASK_ERROR_STATUS = Object.freeze({
  task_unknown: 404,
  task_not_finished: 409,
  result_unavailable: 404,
  approval_not_pending: 409,
  agent_unreachable: 502,
  dispatch_failed: 502,
});

// Hop-by-hop headers are connection-scoped; forwarding them through a proxy is
// how request smuggling and connection confusion start.
const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

// Every entry below exists because the desktop itself calls it. `:id` matches a
// single path segment and nothing else.
export const HERMES_ROUTE_ALLOWLIST = Object.freeze([
  // hermesClient.capabilities() — health + capability probe.
  { method: "GET", pattern: "/v1/capabilities" },
  // main.mjs submitHermesTask() — create a run.
  { method: "POST", pattern: "/v1/runs" },
  // main.mjs getHermesTaskStatus()/watchHermesRun() — run status polling.
  { method: "GET", pattern: "/v1/runs/:id" },
  // main.mjs streamHermesEvents() — SSE activity stream.
  { method: "GET", pattern: "/v1/runs/:id/events" },
  // main.mjs stopHermesTask().
  { method: "POST", pattern: "/v1/runs/:id/stop" },
  // main.mjs approveHermesAction() — approval / interaction response.
  { method: "POST", pattern: "/v1/runs/:id/approval" },
  // main.mjs listHermesSessions().
  { method: "GET", pattern: "/api/sessions" },
  // main.mjs createHermesSession().
  { method: "POST", pattern: "/api/sessions" },
  // main.mjs sessionRunsFromTranscript() — session history and stored results.
  { method: "GET", pattern: "/api/sessions/:id/messages" },
]);

const COMPILED_ALLOWLIST = HERMES_ROUTE_ALLOWLIST.map((route) => ({
  method: route.method,
  pattern: route.pattern,
  segments: route.pattern.split("/").filter(Boolean),
}));

// Normalize BEFORE matching so `..`, `//`, and percent-encoded slashes cannot
// reach a path the allowlist never approved.
export function normalizeProxyPath(rawPath) {
  const input = String(rawPath || "");
  if (!input.startsWith("/")) return null;
  const segments = [];
  for (const rawSegment of input.split("/")) {
    if (!rawSegment) continue;
    let segment;
    try {
      segment = decodeURIComponent(rawSegment);
    } catch {
      return null;
    }
    if (segment === "." || segment === "..") return null;
    // A segment that still contains a separator after decoding was an attempt
    // to smuggle one past the split above.
    if (/[/\\]/.test(segment)) return null;
    if (/[\x00-\x1f\x7f]/.test(segment)) return null;
    segments.push(segment);
  }
  return { path: `/${segments.join("/")}`, segments };
}

export function matchHermesRoute(method, segments) {
  const upper = String(method || "").toUpperCase();
  return (
    COMPILED_ALLOWLIST.find(
      (route) =>
        route.method === upper &&
        route.segments.length === segments.length &&
        route.segments.every(
          (part, index) => (part.startsWith(":") ? segments[index].length > 0 : part === segments[index]),
        ),
    ) || null
  );
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload ?? {});
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on("data", (chunk) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        const error = new Error("payload_too_large");
        error.code = "payload_too_large";
        req.destroy(error);
        reject(error);
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function isJsonContentType(value) {
  const type = String(value || "").split(";")[0].trim().toLowerCase();
  return type === "application/json";
}

function createRateLimiter({ windowMs, max }) {
  const hits = new Map();
  return {
    allow(key) {
      const at = Date.now();
      const bucket = (hits.get(key) || []).filter((time) => at - time < windowMs);
      if (bucket.length >= max) {
        hits.set(key, bucket);
        return false;
      }
      bucket.push(at);
      hits.set(key, bucket);
      if (hits.size > 512) {
        for (const [existing, times] of hits) {
          if (!times.some((time) => at - time < windowMs)) hits.delete(existing);
        }
      }
      return true;
    },
  };
}

function safeQuery(rawQuery) {
  if (!rawQuery) return "";
  const params = new URLSearchParams(rawQuery);
  const serialized = params.toString();
  return serialized ? `?${serialized}` : "";
}

export function createIrisLinkServer({
  pairingStore,
  mintGeminiToken,
  hermes = {},
  // The high-level task API is injected so this file stays Electron-free: the
  // real implementations live in main.mjs and go through exactly the same
  // functions the desktop's own voice session uses.
  tasks = {},
  checkHermesReachable = null,
  getInfo = () => ({}),
  now = () => Date.now(),
  log = () => {},
} = {}) {
  if (!pairingStore) throw new Error("createIrisLinkServer requires a pairingStore.");
  const hermesBaseUrl = String(hermes.baseUrl || "http://127.0.0.1:8642").replace(/\/$/, "");
  const getApiKey = hermes.getApiKey || (() => "");
  const getSessionKey = hermes.getSessionKey || (() => "");
  const fetchImpl = hermes.fetchImpl || globalThis.fetch;
  const pairLimiter = createRateLimiter(PAIR_RATE_LIMIT);

  // Log lines are built here and nowhere else, so no credential, token,
  // pairing secret or shared key can reach them.
  const logEvent = (level, message, detail = {}) => {
    try {
      log({ level, message, ...detail });
    } catch {
      // Logging must never fail a request.
    }
  };

  async function handlePair(req, res, body) {
    const remote = req.socket?.remoteAddress || "unknown";
    if (!pairLimiter.allow(remote)) {
      logEvent("warn", "Iris Link refused a pairing attempt: rate limited.");
      sendJson(res, 429, { error: "rate_limited" });
      return;
    }
    let payload;
    try {
      payload = JSON.parse(body.toString("utf8") || "{}");
    } catch {
      sendJson(res, 400, { error: "invalid_json" });
      return;
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      sendJson(res, 400, { error: "invalid_json" });
      return;
    }
    const result = pairingStore.redeemOffer(String(payload.secret || ""), payload.deviceName);
    if (!result.ok) {
      logEvent("warn", `Iris Link refused a pairing attempt: ${result.error}.`);
      const status = result.error === "too_many_attempts" ? 429 : 400;
      sendJson(res, status, { error: result.error });
      return;
    }
    logEvent("info", `Iris Link paired a new device (${result.device.name}).`, {
      deviceId: result.deviceId,
    });
    sendJson(res, 200, {
      deviceId: result.deviceId,
      credential: result.credential,
      code: pairingStore.getOffer()?.code || "",
    });
  }

  // A cheap, time-bounded, briefly cached reachability probe. A slow or hung
  // Hermes must never hold a phone's status request open, and a failure here
  // means "not reachable", never an exception.
  let hermesStatusCache = { at: 0, value: false, inFlight: null };
  async function freshHermesReachable(fallback) {
    if (typeof checkHermesReachable !== "function") return Boolean(fallback);
    const at = now();
    if (at - hermesStatusCache.at < HERMES_STATUS_CACHE_MS) return hermesStatusCache.value;
    if (!hermesStatusCache.inFlight) {
      const probe = (async () => {
        try {
          return Boolean(await checkHermesReachable());
        } catch {
          return false;
        }
      })();
      hermesStatusCache.inFlight = Promise.race([
        probe,
        new Promise((resolve) => setTimeout(() => resolve(null), HERMES_STATUS_TIMEOUT_MS).unref?.()),
      ]).then((value) => {
        hermesStatusCache.inFlight = null;
        // A probe that timed out tells us nothing new; keep the last answer
        // rather than inventing one, but do not cache the non-answer.
        if (value === null) return hermesStatusCache.value;
        hermesStatusCache = { at: now(), value, inFlight: null };
        return value;
      });
    }
    return hermesStatusCache.inFlight;
  }

  async function handleStatus(res, device) {
    const info = getInfo() || {};
    sendJson(res, 200, {
      ok: true,
      deviceId: device.id,
      deviceName: device.name,
      hermesReachable: await freshHermesReachable(info.hermesReachable),
      // A boolean and nothing else: whether this Mac can push at all. The
      // phone uses it to explain why a registration will not produce alerts.
      pushConfigured: Boolean(info.pushConfigured),
      userName: info.userName || "",
      liveModel: info.liveModel || "",
      voice: info.voice || "",
      accent: info.accent || "",
      // Lets the phone build its own voice picker without hardcoding the
      // catalogue: the same {name, style} list Settings shows on the desktop.
      voices: Array.isArray(info.voices) ? info.voices : [],
      default_voice: info.defaultVoice || info.voice || "",
    });
  }

  // Body is optional and, when present, only ever shapes WHICH catalogue
  // voice and WHAT KIND of token get minted — never anything that reaches the
  // model's config directly. The injected mintGeminiToken owns the actual
  // catalogue lookup (or a validator it was given) so this file never has to
  // import the voice list to stay correct.
  async function handleGeminiToken(res, body) {
    if (typeof mintGeminiToken !== "function") {
      sendJson(res, 502, { error: "token_unavailable" });
      return;
    }
    let payload;
    try {
      payload = JSON.parse(body?.toString("utf8") || "{}");
    } catch {
      sendJson(res, 400, { error: "invalid_json" });
      return;
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      sendJson(res, 400, { error: "invalid_json" });
      return;
    }
    const purpose = payload.purpose === undefined ? "session" : String(payload.purpose);
    if (!GEMINI_TOKEN_PURPOSES.includes(purpose)) {
      sendJson(res, 400, { error: "invalid_purpose" });
      return;
    }
    const voice = payload.voice === undefined ? undefined : String(payload.voice);
    // A phone cannot present a resumption handle itself: the token's config
    // replaces its setup frame (measured against the live API), so the handle
    // has to be baked into the token here. It is opaque to us; only bound it.
    let resumeHandle;
    if (payload.resume_handle !== undefined && payload.resume_handle !== null) {
      const handle = String(payload.resume_handle);
      if (!handle || handle.length > 2048 || /[\x00-\x1f\x7f]/.test(handle) || purpose !== "session") {
        sendJson(res, 400, { error: "invalid_resume_handle" });
        return;
      }
      resumeHandle = handle;
    }
    try {
      const minted = await mintGeminiToken({ voice, purpose, resumeHandle });
      if (minted?.error) {
        sendJson(res, 400, { error: String(minted.error) });
        return;
      }
      if (!minted?.token) throw new Error("no token");
      sendJson(res, 200, {
        token: minted.token,
        expiresAt: minted.expiresAt || null,
        newSessionExpiresAt: minted.newSessionExpiresAt || null,
        model: minted.model || "",
        voice: minted.voice || "",
        purpose: minted.purpose || purpose,
        // True only when the token really carries the handle. The phone must not
        // infer resumption from having asked.
        resumed: Boolean(minted.resumed),
      });
    } catch (error) {
      // The upstream error body can carry the API key back; it never leaves here.
      logEvent("error", `Iris Link could not mint a Gemini token: ${String(error?.name || "Error")}`);
      sendJson(res, 502, { error: "token_unavailable" });
    }
  }

  // ===== Push registration =====
  //
  // The phone hands over the APNs device token it was issued and which APNs
  // environment that token belongs to. It is stored against the calling
  // device only, replaces any previous token, and is never read back out.
  function handlePushRegister(res, device, body) {
    let payload;
    try {
      payload = JSON.parse(body.toString("utf8") || "{}");
    } catch {
      sendJson(res, 400, { error: "invalid_json" });
      return;
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      sendJson(res, 400, { error: "invalid_json" });
      return;
    }
    if (typeof pairingStore.setPushToken !== "function") {
      sendJson(res, 501, { error: "push_unavailable" });
      return;
    }
    const result = pairingStore.setPushToken(device.id, {
      token: payload.token,
      environment: payload.environment,
    });
    if (!result?.ok) {
      const code = String(result?.error || "invalid_token");
      sendJson(res, code === "unknown_device" ? 401 : 400, { error: code });
      return;
    }
    logEvent("info", "Iris Link registered a push token for a paired device.", {
      deviceId: device.id,
    });
    sendJson(res, 200, { ok: true, pushEnabled: true, environment: result.environment });
  }

  // ===== Live Activity tokens =====
  //
  // Two registrations, deliberately separate routes because they are two
  // different capabilities with two different lifetimes (LINK_API.md §14):
  // the per-device push-to-start token, and the per-activity update token.
  // Neither is ever returned by any route, and revoking the device deletes
  // both along with its credential.
  function handleLiveActivityRegister(res, device, body) {
    const payload = parseJsonBody(res, body);
    if (!payload) return;
    if (typeof pairingStore.setLiveActivityToken !== "function") {
      sendJson(res, 501, { error: "push_unavailable" });
      return;
    }
    const result = pairingStore.setLiveActivityToken(device.id, {
      activityId: payload.activity_id,
      token: payload.token,
      environment: payload.environment,
    });
    if (!result?.ok) {
      const code = String(result?.error || "invalid_token");
      sendJson(res, code === "unknown_device" ? 401 : 400, { error: code });
      return;
    }
    logEvent("info", "Iris Link registered a Live Activity update token.", { deviceId: device.id });
    sendJson(res, 200, { ok: true, activity_id: result.activityId, liveActivityEnabled: true });
  }

  function handleLiveActivityUnregister(res, device, rawQuery) {
    if (typeof pairingStore.clearLiveActivityToken !== "function") {
      sendJson(res, 501, { error: "push_unavailable" });
      return;
    }
    // No `activity_id` means "all of them": the user turned Live Activities
    // off and the Mac must stop pushing to every one it holds.
    const activityId = new URLSearchParams(rawQuery || "").get("activity_id") || "";
    const result = pairingStore.clearLiveActivityToken(device.id, activityId);
    if (!result?.ok) {
      const code = String(result?.error || "unknown_device");
      sendJson(res, code === "unknown_device" ? 401 : 400, { error: code });
      return;
    }
    sendJson(res, 200, { ok: true, liveActivityEnabled: false });
  }

  function handlePushToStartRegister(res, device, body) {
    const payload = parseJsonBody(res, body);
    if (!payload) return;
    if (typeof pairingStore.setLiveActivityStartToken !== "function") {
      sendJson(res, 501, { error: "push_unavailable" });
      return;
    }
    const result = pairingStore.setLiveActivityStartToken(device.id, {
      token: payload.token,
      environment: payload.environment,
    });
    if (!result?.ok) {
      const code = String(result?.error || "invalid_token");
      sendJson(res, code === "unknown_device" ? 401 : 400, { error: code });
      return;
    }
    logEvent("info", "Iris Link registered a push-to-start token.", { deviceId: device.id });
    sendJson(res, 200, { ok: true, pushToStartEnabled: true, environment: result.environment });
  }

  function handlePushToStartUnregister(res, device) {
    if (typeof pairingStore.clearLiveActivityStartToken !== "function") {
      sendJson(res, 501, { error: "push_unavailable" });
      return;
    }
    const result = pairingStore.clearLiveActivityStartToken(device.id);
    if (!result?.ok) {
      sendJson(res, 401, { error: "not_paired" });
      return;
    }
    sendJson(res, 200, { ok: true, pushToStartEnabled: false });
  }

  // The home-screen widget's timeline provider calls this and nothing else:
  // counts, two titles and a reachability flag. No step lists, no result text,
  // no output — a widget is a glance, and iOS will refresh it on its own
  // budget whatever we would like.
  async function handleSummary(res, device) {
    const handler = tasks?.summary;
    if (typeof handler !== "function") {
      sendJson(res, 501, { error: "tasks_unavailable" });
      return;
    }
    const summary = (await handler({ deviceId: device.id })) || {};
    const info = getInfo() || {};
    sendJson(res, 200, {
      active_count: Number(summary.active_count) || 0,
      waiting_count: Number(summary.waiting_count) || 0,
      finished_today_count: Number(summary.finished_today_count) || 0,
      active_run: summary.active_run || null,
      last_finished: summary.last_finished || null,
      hermesReachable: await freshHermesReachable(info.hermesReachable),
      generated_at: now(),
    });
  }

  function handlePushUnregister(res, device) {
    if (typeof pairingStore.clearPushToken !== "function") {
      sendJson(res, 501, { error: "push_unavailable" });
      return;
    }
    const result = pairingStore.clearPushToken(device.id);
    if (!result?.ok) {
      sendJson(res, 401, { error: "not_paired" });
      return;
    }
    sendJson(res, 200, { ok: true, pushEnabled: false });
  }

  // ===== High-level task API =====
  //
  // These routes exist so the phone never has to reimplement dispatch: a task
  // posted here goes through the desktop's own submit path, which is what
  // keeps the pinned Hermes session, the safety instructions, the memory key,
  // the run registry and the desktop's task card in play.
  function parseJsonBody(res, body) {
    let payload;
    try {
      payload = JSON.parse(body.toString("utf8") || "{}");
    } catch {
      sendJson(res, 400, { error: "invalid_json" });
      return null;
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      sendJson(res, 400, { error: "invalid_json" });
      return null;
    }
    return payload;
  }

  function requireHandler(res, name) {
    const handler = tasks?.[name];
    if (typeof handler !== "function") {
      sendJson(res, 501, { error: "tasks_unavailable" });
      return null;
    }
    return handler;
  }

  function sendTaskError(res, error, message) {
    const code = String(error || "internal_error");
    sendJson(res, TASK_ERROR_STATUS[code] || 500, {
      error: code,
      ...(message ? { message: String(message).slice(0, 500) } : {}),
    });
  }

  async function handleTaskDispatch(res, device, body) {
    const handler = requireHandler(res, "dispatch");
    if (!handler) return;
    const payload = parseJsonBody(res, body);
    if (!payload) return;
    const task = String(payload.task ?? "").trim();
    if (!task) {
      sendJson(res, 400, { error: "task_required" });
      return;
    }
    if (task.length > MAX_TASK_CHARS) {
      sendJson(res, 400, { error: "task_too_long" });
      return;
    }
    const urgency = payload.urgency === undefined ? "normal" : String(payload.urgency);
    if (!TASK_URGENCIES.includes(urgency)) {
      sendJson(res, 400, { error: "invalid_urgency" });
      return;
    }
    try {
      const result = await handler({ task, urgency, deviceId: device.id });
      if (result?.error) {
        sendTaskError(res, result.error, result.message);
        return;
      }
      if (!result?.run_id) {
        sendTaskError(res, "dispatch_failed", result?.message || "Hermes did not return a run id.");
        return;
      }
      logEvent("info", `Iris Link dispatched a task from a paired device.`, { deviceId: device.id });
      sendJson(res, 200, {
        status: String(result.status || "started"),
        run_id: String(result.run_id),
        message: String(result.message || "Hermes has started the task."),
        origin: String(result.origin || `device:${device.id}`),
      });
    } catch (error) {
      logEvent("warn", `Iris Link could not dispatch a task: ${String(error?.name || "Error")}`);
      sendTaskError(res, "agent_unreachable", error?.message);
    }
  }

  async function handleTaskList(res, device, rawQuery) {
    const handler = requireHandler(res, "list");
    if (!handler) return;
    const params = new URLSearchParams(rawQuery || "");
    const undelivered = params.get("undelivered") === "1";
    const list = (await handler({ deviceId: device.id, undelivered })) || [];
    sendJson(res, 200, { tasks: Array.isArray(list) ? list : [] });
  }

  // `?steps_since=<cursor|step id>` lets a polling phone ask for only the
  // steps that are new or changed since its last read. It is advisory: an
  // unparseable value simply returns the whole retained list.
  async function handleTaskGet(res, runId, rawQuery) {
    const handler = requireHandler(res, "get");
    if (!handler) return;
    const stepsSince = new URLSearchParams(rawQuery || "").get("steps_since") || "";
    const status = await handler({ runId, stepsSince: stepsSince.slice(0, 40) });
    if (!status || status.error === "task_unknown") {
      sendJson(res, 404, { error: "task_unknown" });
      return;
    }
    sendJson(res, 200, status);
  }

  async function handleTaskResult(res, runId) {
    const handler = requireHandler(res, "result");
    if (!handler) return;
    const result = await handler({ runId });
    if (!result || result.ok === false) {
      sendTaskError(res, result?.error || "task_unknown", result?.message);
      return;
    }
    sendJson(res, 200, result);
  }

  async function handleTaskStop(res, runId) {
    const handler = requireHandler(res, "stop");
    if (!handler) return;
    try {
      const result = await handler({ runId });
      if (result?.ok === false) {
        sendTaskError(res, result.error || "task_unknown", result.message);
        return;
      }
      sendJson(res, 200, { status: String(result?.status || "stopping"), run_id: runId });
    } catch (error) {
      sendTaskError(res, "agent_unreachable", error?.message);
    }
  }

  async function handleTaskApproval(res, runId, body) {
    const handler = requireHandler(res, "approve");
    if (!handler) return;
    const payload = parseJsonBody(res, body);
    if (!payload) return;
    const decision = String(payload.decision ?? "").trim().toLowerCase();
    if (!APPROVAL_DECISIONS.includes(decision)) {
      sendJson(res, 400, { error: "invalid_decision" });
      return;
    }
    try {
      const result = await handler({ runId, decision });
      if (result?.ok === false) {
        sendTaskError(res, result.error || "approval_not_pending", result.message);
        return;
      }
      sendJson(res, 200, { status: "resolved", run_id: runId, decision });
    } catch (error) {
      sendTaskError(res, "agent_unreachable", error?.message);
    }
  }

  async function handleTaskAnnounced(res, device, runId) {
    const handler = requireHandler(res, "markAnnounced");
    if (!handler) return;
    const result = await handler({ runId, deviceId: device.id });
    if (result?.ok === false) {
      sendTaskError(res, result.error || "task_unknown", result.message);
      return;
    }
    sendJson(res, 200, { ok: true, run_id: runId });
  }

  // `/link/tasks`, `/link/tasks/:id`, `/link/tasks/:id/<action>` and nothing
  // else. Returns null when the path is not a task route at all.
  function matchTaskRoute(rawPath) {
    if (rawPath === "/link/tasks") return { runId: "", action: "" };
    if (!rawPath.startsWith("/link/tasks/")) return null;
    const segments = rawPath.slice("/link/tasks/".length).split("/");
    if (segments.length > 2) return null;
    let runId;
    try {
      runId = decodeURIComponent(segments[0] || "");
    } catch {
      return null;
    }
    if (!runId || runId.length > 200 || /[\x00-\x1f/\\]/.test(runId)) return null;
    return { runId, action: segments[1] || "" };
  }

  async function handleProxy(req, res, rest, rawQuery, body) {
    const normalized = normalizeProxyPath(rest);
    if (!normalized) {
      sendJson(res, 403, { error: "route_not_allowed" });
      return;
    }
    const route = matchHermesRoute(req.method, normalized.segments);
    if (!route) {
      logEvent("warn", `Iris Link refused a non-allowlisted route: ${req.method} ${normalized.path}`);
      sendJson(res, 403, { error: "route_not_allowed" });
      return;
    }
    const upstreamPath = `/${normalized.segments.map((segment) => encodeURIComponent(segment)).join("/")}`;
    const controller = new AbortController();
    const onClose = () => controller.abort();
    // A phone that walks out of range must not leave an SSE read hanging on
    // Hermes forever.
    res.on("close", onClose);
    const timer = route.pattern.endsWith("/events")
      ? null
      : setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);

    try {
      const headers = {
        Authorization: `Bearer ${getApiKey()}`,
        Accept: String(req.headers.accept || "application/json"),
      };
      const sessionKey = getSessionKey();
      if (sessionKey) headers["X-Hermes-Session-Key"] = sessionKey;
      if (body?.length) headers["Content-Type"] = "application/json";

      const upstream = await fetchImpl(`${hermesBaseUrl}${upstreamPath}${safeQuery(rawQuery)}`, {
        method: req.method,
        headers,
        body: body?.length ? body : undefined,
        signal: controller.signal,
      });

      const contentType = upstream.headers?.get?.("content-type") || "application/json";
      // Only the content type crosses back: anything else upstream sets could
      // reflect internals, and the shared key must never appear in a response.
      res.writeHead(upstream.status, {
        "Content-Type": contentType,
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
      });
      res.flushHeaders?.();

      const stream = upstream.body;
      if (!stream) {
        res.end();
        return;
      }
      const reader = stream.getReader();
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          if (!res.writableEnded) res.write(Buffer.from(value));
        }
      } finally {
        try {
          reader.releaseLock?.();
        } catch {
          // Stream already torn down.
        }
      }
      if (!res.writableEnded) res.end();
    } catch (error) {
      if (controller.signal.aborted && res.writableEnded) return;
      logEvent("warn", `Iris Link could not reach Hermes for ${req.method} ${normalized.path}.`);
      if (res.headersSent) {
        res.end();
        return;
      }
      sendJson(res, 502, { error: "agent_unreachable" });
    } finally {
      if (timer) clearTimeout(timer);
      res.off("close", onClose);
    }
  }

  async function route(req, res) {
    const rawUrl = String(req.url || "/");
    const queryIndex = rawUrl.indexOf("?");
    const rawPath = queryIndex === -1 ? rawUrl : rawUrl.slice(0, queryIndex);
    const rawQuery = queryIndex === -1 ? "" : rawUrl.slice(queryIndex + 1);
    const method = String(req.method || "GET").toUpperCase();

    const expectsBody = method === "POST" || method === "PUT" || method === "PATCH";
    let body = Buffer.alloc(0);
    if (expectsBody) {
      if (req.headers["content-type"] && !isJsonContentType(req.headers["content-type"])) {
        sendJson(res, 415, { error: "unsupported_media_type" });
        return;
      }
      try {
        body = await readBody(req);
      } catch (error) {
        if (error?.code === "payload_too_large") {
          if (!res.headersSent) sendJson(res, 413, { error: "payload_too_large" });
          return;
        }
        if (!res.headersSent) sendJson(res, 400, { error: "invalid_request" });
        return;
      }
    }

    if (rawPath === "/link/pair") {
      if (method !== "POST") {
        sendJson(res, 405, { error: "method_not_allowed" });
        return;
      }
      await handlePair(req, res, body);
      return;
    }

    // Everything past this point is device-authenticated. Refusal is explicit:
    // `not_paired`, never an empty result or a fake agent error.
    const auth = String(req.headers.authorization || "");
    const credential = /^Bearer\s+(.+)$/i.exec(auth)?.[1]?.trim() || "";
    const device = credential ? pairingStore.authenticate(credential) : null;
    if (!device) {
      logEvent("warn", `Iris Link refused an unauthenticated request: ${method} ${rawPath}`);
      sendJson(res, 401, { error: "not_paired" });
      return;
    }

    if (rawPath === "/link/status") {
      if (method !== "GET") {
        sendJson(res, 405, { error: "method_not_allowed" });
        return;
      }
      await handleStatus(res, device);
      return;
    }

    if (rawPath === "/link/push-token") {
      if (method === "PUT") handlePushRegister(res, device, body);
      else if (method === "DELETE") handlePushUnregister(res, device);
      else sendJson(res, 405, { error: "method_not_allowed" });
      return;
    }

    if (rawPath === "/link/live-activity") {
      if (method === "PUT") handleLiveActivityRegister(res, device, body);
      else if (method === "DELETE") handleLiveActivityUnregister(res, device, rawQuery);
      else sendJson(res, 405, { error: "method_not_allowed" });
      return;
    }

    if (rawPath === "/link/live-activity/start-token") {
      if (method === "PUT") handlePushToStartRegister(res, device, body);
      else if (method === "DELETE") handlePushToStartUnregister(res, device);
      else sendJson(res, 405, { error: "method_not_allowed" });
      return;
    }

    if (rawPath === "/link/summary") {
      if (method !== "GET") {
        sendJson(res, 405, { error: "method_not_allowed" });
        return;
      }
      await handleSummary(res, device);
      return;
    }

    if (rawPath === "/link/tasks" || rawPath.startsWith("/link/tasks/")) {
      const target = matchTaskRoute(rawPath);
      if (!target) {
        sendJson(res, 404, { error: "not_found" });
        return;
      }
      if (!target.runId) {
        if (method === "POST") await handleTaskDispatch(res, device, body);
        else if (method === "GET") await handleTaskList(res, device, rawQuery);
        else sendJson(res, 405, { error: "method_not_allowed" });
        return;
      }
      if (!target.action) {
        if (method === "GET") await handleTaskGet(res, target.runId, rawQuery);
        else sendJson(res, 405, { error: "method_not_allowed" });
        return;
      }
      if (target.action === "result") {
        if (method === "GET") await handleTaskResult(res, target.runId);
        else sendJson(res, 405, { error: "method_not_allowed" });
        return;
      }
      if (target.action === "stop") {
        if (method === "POST") await handleTaskStop(res, target.runId);
        else sendJson(res, 405, { error: "method_not_allowed" });
        return;
      }
      if (target.action === "approval") {
        if (method === "POST") await handleTaskApproval(res, target.runId, body);
        else sendJson(res, 405, { error: "method_not_allowed" });
        return;
      }
      if (target.action === "announced") {
        if (method === "POST") await handleTaskAnnounced(res, device, target.runId);
        else sendJson(res, 405, { error: "method_not_allowed" });
        return;
      }
      sendJson(res, 404, { error: "not_found" });
      return;
    }

    if (rawPath === "/link/gemini-token") {
      if (method !== "POST") {
        sendJson(res, 405, { error: "method_not_allowed" });
        return;
      }
      await handleGeminiToken(res, body);
      return;
    }

    if (rawPath === "/hermes" || rawPath.startsWith("/hermes/")) {
      await handleProxy(req, res, rawPath.slice("/hermes".length) || "/", rawQuery, body);
      return;
    }

    sendJson(res, 404, { error: "not_found" });
  }

  const server = http.createServer((req, res) => {
    route(req, res).catch((error) => {
      logEvent("error", `Iris Link request failed: ${String(error?.name || "Error")}`);
      if (!res.headersSent) sendJson(res, 500, { error: "internal_error" });
      else if (!res.writableEnded) res.end();
    });
  });
  server.headersTimeout = HEADERS_TIMEOUT_MS;
  server.requestTimeout = REQUEST_TIMEOUT_MS;
  server.keepAliveTimeout = 15_000;

  return {
    listen({ host, port }) {
      return new Promise((resolve, reject) => {
        const onError = (error) => {
          server.off("listening", onListening);
          reject(error);
        };
        const onListening = () => {
          server.off("error", onError);
          resolve(server.address());
        };
        server.once("error", onError);
        server.once("listening", onListening);
        server.listen(port, host);
      });
    },
    close() {
      return new Promise((resolve) => {
        server.closeAllConnections?.();
        server.close(() => resolve());
      });
    },
    address() {
      return server.address();
    },
  };
}
