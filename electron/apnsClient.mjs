import crypto from "node:crypto";
import fs from "node:fs";
import http2 from "node:http2";
import os from "node:os";
import path from "node:path";

// Push comes from this Mac, straight to Apple: a hand-rolled ES256 provider
// JWT over HTTP/2, no relay and no npm dependency. Everything here is
// dependency-injected (key loader, clock, http2 connect) so it is testable
// without a network and importable without Electron.
export const APNS_HOSTS = Object.freeze({
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
});
export const APNS_ENVIRONMENTS = Object.freeze(["sandbox", "production"]);
export const APNS_DEFAULT_TOPIC = "app.iris.liveprototype";

// Apple rejects a provider token older than one hour and refuses to mint a
// replacement more than once every twenty minutes. Refresh comfortably inside
// the first limit; never regenerate inside the second.
export const JWT_REFRESH_MS = 50 * 60_000;
export const JWT_MIN_REGENERATE_MS = 20 * 60_000;
export const APNS_REQUEST_TIMEOUT_MS = 10_000;
const SESSION_IDLE_TIMEOUT_MS = 5 * 60_000;

// A token Apple says is dead for this topic: stop sending to it, permanently.
const DROP_REASONS = new Set(["Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"]);

// A device token is lowercase hex. Anything else is a typo or an attack, and
// sending it would burn a request to learn what a regex already knows.
export function isValidDeviceToken(value) {
  const token = String(value ?? "").trim();
  if (token.length < 64 || token.length > 200) return false;
  if (token.length % 2 !== 0) return false;
  return /^[0-9a-fA-F]+$/.test(token);
}

export function normalizeApnsEnvironment(value) {
  const environment = String(value ?? "").trim().toLowerCase();
  return APNS_ENVIRONMENTS.includes(environment) ? environment : null;
}

// Logs and errors get at most this much of a device token: enough to correlate
// two lines, never enough to push to a user's phone.
export function maskDeviceToken(value) {
  return String(value ?? "").slice(0, 8);
}

function base64url(input) {
  return Buffer.from(input).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function buildApnsJwt({ keyId, teamId, privateKey, issuedAt, sign = crypto.sign }) {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: String(keyId) }));
  const claims = base64url(JSON.stringify({ iss: String(teamId), iat: Math.floor(issuedAt) }));
  const signingInput = `${header}.${claims}`;
  // APNs wants the raw r||s pair, not the DER structure Node signs by default.
  const signature = sign("sha256", Buffer.from(signingInput), {
    key: privateKey,
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${base64url(signature)}`;
}

// Config discovery: explicit env wins, otherwise exactly one ~/.iris/AuthKey_*.p8
// is taken as the key and its filename as the key id. A missing piece disables
// push with a reason — never an exception, never a dialog.
export function resolveApnsConfig({ env = process.env, homeDir = os.homedir(), fsImpl = fs } = {}) {
  const topic = String(env.IRIS_APNS_TOPIC || APNS_DEFAULT_TOPIC).trim();
  const teamId = String(env.IRIS_APNS_TEAM_ID || "").trim();
  let keyPath = String(env.IRIS_APNS_KEY_PATH || "").trim();
  let keyId = String(env.IRIS_APNS_KEY_ID || "").trim();

  if (keyPath.startsWith("~")) keyPath = path.join(homeDir, keyPath.slice(1));
  if (!keyPath) {
    const dir = path.join(homeDir, ".iris");
    let candidates = [];
    try {
      candidates = fsImpl.readdirSync(dir).filter((name) => /^AuthKey_.+\.p8$/.test(name));
    } catch {
      candidates = [];
    }
    if (candidates.length !== 1) {
      return { ok: false, reason: candidates.length ? "multiple_keys" : "no_key" };
    }
    keyPath = path.join(dir, candidates[0]);
  }
  if (!keyId) keyId = /^AuthKey_(.+)\.p8$/.exec(path.basename(keyPath))?.[1] || "";
  if (!keyId) return { ok: false, reason: "no_key_id" };
  if (!teamId) return { ok: false, reason: "no_team_id" };
  if (!topic) return { ok: false, reason: "no_topic" };
  return { ok: true, keyPath, keyId, teamId, topic };
}

function parseReason(status, chunks) {
  if (status === 200) return "";
  const body = Buffer.concat(chunks).toString("utf8").slice(0, 2000);
  if (!body) return "";
  try {
    const parsed = JSON.parse(body);
    return typeof parsed?.reason === "string" ? parsed.reason : "";
  } catch {
    return "";
  }
}

function classify(result) {
  const status = Number(result?.status) || 0;
  if (status === 200) return { ok: true, status: 200, reason: "", unregistered: false };
  const reason = result?.reason || result?.error || (status ? `http_${status}` : "unreachable");
  const unregistered = status === 410 || (status === 400 && DROP_REASONS.has(result?.reason));
  return { ok: false, status, reason, unregistered };
}

export function createApnsClient({
  keyId,
  teamId,
  topic,
  loadKey,
  now = () => Date.now(),
  connect = http2.connect,
  requestTimeoutMs = APNS_REQUEST_TIMEOUT_MS,
  log = () => {},
} = {}) {
  const sessions = new Map();
  let jwt = "";
  let jwtIssuedAt = 0;

  const safeLog = (message) => {
    try {
      log(message);
    } catch {
      // Logging must never fail a push.
    }
  };

  // The JWT is minted at most every JWT_MIN_REGENERATE_MS and reused until it
  // is JWT_REFRESH_MS old. `force` is the ExpiredProviderToken path and is
  // still subject to the regeneration floor.
  function providerToken({ force = false } = {}) {
    const at = now();
    const age = at - jwtIssuedAt;
    if (jwt && !force && age < JWT_REFRESH_MS) return jwt;
    if (jwt && age < JWT_MIN_REGENERATE_MS) return jwt;
    const privateKey = loadKey();
    if (!privateKey) throw new Error("apns_key_unavailable");
    jwt = buildApnsJwt({ keyId, teamId, privateKey, issuedAt: Math.floor(at / 1000) });
    jwtIssuedAt = at;
    return jwt;
  }

  function dropSession(host, session) {
    if (!session || sessions.get(host) === session) sessions.delete(host);
  }

  function getSession(host) {
    const existing = sessions.get(host);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const session = connect(host);
    sessions.set(host, session);
    // A GOAWAY, an error or a close means this session is finished; the next
    // send reconnects rather than writing into a dead socket.
    session.on?.("error", (error) => {
      dropSession(host, session);
      safeLog(`APNs connection error: ${String(error?.code || error?.name || "Error")}`);
    });
    session.on?.("goaway", () => dropSession(host, session));
    session.on?.("close", () => dropSession(host, session));
    session.setTimeout?.(SESSION_IDLE_TIMEOUT_MS, () => {
      dropSession(host, session);
      session.destroy?.();
    });
    return session;
  }

  function post({ host, path: requestPath, headers, body }) {
    return new Promise((resolve) => {
      let settled = false;
      const finish = (value) => {
        if (settled) return;
        settled = true;
        resolve(value);
      };
      let session;
      try {
        session = getSession(host);
      } catch {
        finish({ status: 0, error: "connect_failed" });
        return;
      }
      let request;
      try {
        request = session.request({ ":method": "POST", ":path": requestPath, ...headers });
      } catch {
        dropSession(host, session);
        finish({ status: 0, error: "request_failed" });
        return;
      }
      let status = 0;
      const chunks = [];
      request.setTimeout?.(requestTimeoutMs, () => {
        try {
          request.close?.(http2.constants?.NGHTTP2_CANCEL ?? 0x8);
        } catch {
          // Already gone.
        }
        finish({ status: 0, error: "timeout" });
      });
      request.on("response", (responseHeaders) => {
        status = Number(responseHeaders?.[":status"]) || 0;
      });
      request.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
      request.on("error", (error) => {
        dropSession(host, session);
        finish({ status: 0, error: String(error?.code || "stream_error") });
      });
      request.on("end", () => finish({ status, reason: parseReason(status, chunks) }));
      try {
        request.end(body);
      } catch {
        finish({ status: 0, error: "write_failed" });
      }
    });
  }

  return {
    // Exposed for tests and diagnostics; never logged or returned to a client.
    _providerToken: providerToken,

    async send({ deviceToken, environment, payload, collapseId, priority, expiration } = {}) {
      if (!keyId || !teamId || !topic) {
        return { ok: false, status: 0, reason: "not_configured", unregistered: false };
      }
      if (!isValidDeviceToken(deviceToken)) {
        // A malformed token can never become valid: treat it like a drop.
        return { ok: false, status: 0, reason: "invalid_token", unregistered: true };
      }
      const env = normalizeApnsEnvironment(environment);
      if (!env) return { ok: false, status: 0, reason: "invalid_environment", unregistered: false };

      const token = String(deviceToken).trim();
      const host = APNS_HOSTS[env];
      let body;
      try {
        body = Buffer.from(JSON.stringify(payload ?? {}));
      } catch {
        return { ok: false, status: 0, reason: "invalid_payload", unregistered: false };
      }

      const attempt = async (force) => {
        let bearer;
        try {
          bearer = providerToken({ force });
        } catch {
          return { status: 0, error: "key_unavailable" };
        }
        const headers = {
          authorization: `bearer ${bearer}`,
          "apns-topic": topic,
          "apns-push-type": "alert",
          "apns-priority": String(priority ?? 10),
          "content-type": "application/json",
          "content-length": String(body.length),
        };
        if (collapseId) headers["apns-collapse-id"] = String(collapseId).slice(0, 64);
        if (expiration != null) headers["apns-expiration"] = String(expiration);
        return post({ host, path: `/3/device/${token}`, headers, body });
      };

      let result = await attempt(false);
      if (result.status === 403 && result.reason === "ExpiredProviderToken") {
        // One regeneration, then one retry. Never a loop.
        result = await attempt(true);
      } else if (!result.status || result.status >= 500) {
        result = await attempt(false);
      }
      const classified = classify(result);
      if (!classified.ok) {
        safeLog(
          `APNs refused a push for ${maskDeviceToken(token)}… (${classified.status || "no response"}: ${classified.reason}).`,
        );
      }
      return classified;
    },

    close() {
      for (const [host, session] of sessions) {
        sessions.delete(host);
        try {
          session.close?.();
        } catch {
          // Best effort.
        }
      }
    },
  };
}
