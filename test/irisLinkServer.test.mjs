import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import {
  HERMES_ROUTE_ALLOWLIST,
  createIrisLinkServer,
  matchHermesRoute,
  normalizeProxyPath,
} from "../electron/irisLinkServer.mjs";
import { createPairingStore } from "../electron/pairingStore.mjs";

const SHARED_KEY = "hermes-shared-key-do-not-leak";

function tempFile() {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), "iris-link-")), "devices.json");
}

// A stand-in for Hermes on loopback: it records what it was asked and can
// stream SSE so the proxy's passthrough is observable.
async function startFakeHermes(handler) {
  const seen = [];
  const server = http.createServer((req, res) => {
    const record = { method: req.method, url: req.url, headers: req.headers, aborted: false };
    seen.push(record);
    req.on("aborted", () => {
      record.aborted = true;
    });
    res.on("close", () => {
      if (!res.writableEnded) record.aborted = true;
    });
    handler(req, res, record);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    seen,
    baseUrl: `http://127.0.0.1:${server.address().port}`,
    async close() {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

async function startLink(options = {}) {
  const logs = [];
  const store = options.pairingStore || createPairingStore({ file: tempFile() });
  const link = createIrisLinkServer({
    pairingStore: store,
    mintGeminiToken:
      options.mintGeminiToken ||
      (async () => ({
        token: "auth_tokens/ephemeral-123",
        expiresAt: "2026-01-01T00:00:00.000Z",
        newSessionExpiresAt: "2026-01-01T00:01:00.000Z",
        model: "models/gemini-3.1-flash-live-preview",
      })),
    hermes: {
      baseUrl: options.hermesBaseUrl || "http://127.0.0.1:1",
      getApiKey: () => SHARED_KEY,
      getSessionKey: () => "iris:desktop:test",
    },
    getInfo: options.getInfo || (() => ({
      hermesReachable: true,
      userName: "Nate",
      liveModel: "models/gemini-3.1-flash-live-preview",
      voice: "Zephyr",
      accent: "cyan",
    })),
    log: (entry) => logs.push(entry),
  });
  const address = await link.listen({ host: "127.0.0.1", port: 0 });
  return {
    store,
    logs,
    origin: `http://127.0.0.1:${address.port}`,
    close: () => link.close(),
  };
}

async function pair(link, name = "iPhone") {
  const offer = link.store.createOffer();
  const response = await fetch(`${link.origin}/link/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret: offer.secret, deviceName: name }),
  });
  return { offer, response, body: await response.json() };
}

test("the allowlist is reviewable data and matches only whole segments", () => {
  assert.equal(Object.isFrozen(HERMES_ROUTE_ALLOWLIST), true);
  assert.ok(HERMES_ROUTE_ALLOWLIST.some((route) => route.method === "POST" && route.pattern === "/v1/runs"));
  assert.ok(matchHermesRoute("GET", ["v1", "runs", "abc", "events"]));
  assert.equal(matchHermesRoute("GET", ["v1", "runs"]), null);
  assert.equal(matchHermesRoute("DELETE", ["v1", "runs", "abc"]), null);
  assert.equal(matchHermesRoute("GET", ["v1", "runs", "abc", "events", "extra"]), null);
});

test("path normalization refuses traversal and encoded separators", () => {
  assert.deepEqual(normalizeProxyPath("/v1//runs///abc"), {
    path: "/v1/runs/abc",
    segments: ["v1", "runs", "abc"],
  });
  assert.equal(normalizeProxyPath("/v1/../admin"), null);
  assert.equal(normalizeProxyPath("/v1/%2e%2e/admin"), null);
  assert.equal(normalizeProxyPath("/v1/runs%2f..%2fadmin"), null);
  assert.equal(normalizeProxyPath("/v1/%zz"), null);
  assert.equal(normalizeProxyPath("v1/runs"), null);
});

test("pairing hands back a credential and a code, then refuses reuse", async (t) => {
  const link = await startLink();
  t.after(() => link.close());

  const { response, body, offer } = await pair(link);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("access-control-allow-origin"), null);
  assert.equal(body.code, offer.code);
  assert.equal(typeof body.credential, "string");
  assert.equal(body.credential.length >= 32, true);

  const replay = await fetch(`${link.origin}/link/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret: offer.secret, deviceName: "Second phone" }),
  });
  assert.equal(replay.status, 400);
  assert.equal((await replay.json()).error, "offer_used");
  assert.equal(link.store.listDevices().length, 1);
});

test("pairing refusals are machine-readable and no secret reaches the log", async (t) => {
  const link = await startLink();
  t.after(() => link.close());

  const offer = link.store.createOffer();
  const wrong = await fetch(`${link.origin}/link/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret: "not-the-secret", deviceName: "Phone" }),
  });
  assert.equal(wrong.status, 400);
  assert.equal((await wrong.json()).error, "offer_unknown");

  const bad = await fetch(`${link.origin}/link/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "not json at all",
  });
  assert.equal(bad.status, 400);
  assert.equal((await bad.json()).error, "invalid_json");

  const wrongMethod = await fetch(`${link.origin}/link/pair`);
  assert.equal(wrongMethod.status, 405);

  const serializedLogs = JSON.stringify(link.logs);
  assert.equal(serializedLogs.includes(offer.secret), false);
  assert.equal(serializedLogs.includes(SHARED_KEY), false);
});

test("the pair route is rate limited per remote address", async (t) => {
  const link = await startLink();
  t.after(() => link.close());
  link.store.createOffer();

  let limited = 0;
  for (let attempt = 0; attempt < 14; attempt += 1) {
    const response = await fetch(`${link.origin}/link/pair`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ secret: "wrong", deviceName: "Phone" }),
    });
    await response.arrayBuffer();
    if (response.status === 429) limited += 1;
  }
  assert.ok(limited > 0, "expected the limiter to refuse some attempts");
});

test("every non-pair route refuses an unauthenticated caller with not_paired", async (t) => {
  const link = await startLink();
  t.after(() => link.close());

  for (const [method, routePath] of [
    ["GET", "/link/status"],
    ["POST", "/link/gemini-token"],
    ["GET", "/hermes/v1/capabilities"],
    ["POST", "/hermes/v1/runs"],
    ["GET", "/link/unknown"],
  ]) {
    for (const headers of [{}, { Authorization: "Bearer wrong-credential" }, { Authorization: "Basic x" }]) {
      const response = await fetch(`${link.origin}${routePath}`, { method, headers });
      assert.equal(response.status, 401, `${method} ${routePath}`);
      assert.deepEqual(await response.json(), { error: "not_paired" });
    }
  }
});

test("a revoked credential is refused with not_paired", async (t) => {
  const link = await startLink();
  t.after(() => link.close());

  const { body } = await pair(link);
  const authorized = { Authorization: `Bearer ${body.credential}` };
  assert.equal((await fetch(`${link.origin}/link/status`, { headers: authorized })).status, 200);

  link.store.revoke(body.deviceId);
  const after = await fetch(`${link.origin}/link/status`, { headers: authorized });
  assert.equal(after.status, 401);
  assert.deepEqual(await after.json(), { error: "not_paired" });
});

test("status reports device identity and nothing secret", async (t) => {
  const link = await startLink();
  t.after(() => link.close());

  const { body } = await pair(link, "Nate's iPhone");
  const response = await fetch(`${link.origin}/link/status`, {
    headers: { Authorization: `Bearer ${body.credential}` },
  });
  const status = await response.json();
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(status, {
    ok: true,
    deviceId: body.deviceId,
    deviceName: "Nate's iPhone",
    hermesReachable: true,
    userName: "Nate",
    liveModel: "models/gemini-3.1-flash-live-preview",
    voice: "Zephyr",
    accent: "cyan",
  });
  const serialized = JSON.stringify(status);
  assert.equal(serialized.includes(SHARED_KEY), false);
  assert.equal(serialized.includes(body.credential), false);
});

test("the token route mints for a paired device and hides upstream failures", async (t) => {
  const link = await startLink();
  t.after(() => link.close());
  const { body } = await pair(link);

  const ok = await fetch(`${link.origin}/link/gemini-token`, {
    method: "POST",
    headers: { Authorization: `Bearer ${body.credential}` },
  });
  assert.equal(ok.status, 200);
  const minted = await ok.json();
  assert.equal(minted.token, "auth_tokens/ephemeral-123");
  assert.equal(minted.model, "models/gemini-3.1-flash-live-preview");

  const failing = await startLink({
    mintGeminiToken: async () => {
      throw new Error(`Gemini rejected key AIzaSy-SECRET-KEY-VALUE`);
    },
  });
  t.after(() => failing.close());
  const paired = await pair(failing);
  const refused = await fetch(`${failing.origin}/link/gemini-token`, {
    method: "POST",
    headers: { Authorization: `Bearer ${paired.body.credential}` },
  });
  assert.equal(refused.status, 502);
  const text = await refused.text();
  assert.deepEqual(JSON.parse(text), { error: "token_unavailable" });
  assert.equal(text.includes("AIzaSy"), false);
  assert.equal(JSON.stringify(failing.logs).includes("AIzaSy"), false);

  const wrongMethod = await fetch(`${link.origin}/link/gemini-token`, {
    headers: { Authorization: `Bearer ${body.credential}` },
  });
  assert.equal(wrongMethod.status, 405);
});

test("an allowlisted proxy call carries the shared key upstream, not the client credential", async (t) => {
  const upstream = await startFakeHermes((req, res) => {
    res.writeHead(200, { "Content-Type": "application/json", "X-Hermes-Internal": "leaky" });
    res.end(JSON.stringify({ run_id: "run-1", echoed: req.url }));
  });
  t.after(() => upstream.close());
  const link = await startLink({ hermesBaseUrl: upstream.baseUrl });
  t.after(() => link.close());
  const { body } = await pair(link);

  const response = await fetch(`${link.origin}/hermes/v1/runs?limit=5`, {
    method: "POST",
    headers: { Authorization: `Bearer ${body.credential}`, "Content-Type": "application/json" },
    body: JSON.stringify({ input: "do the thing" }),
  });
  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.run_id, "run-1");
  assert.equal(payload.echoed, "/v1/runs?limit=5");

  const seen = upstream.seen.at(-1);
  assert.equal(seen.headers.authorization, `Bearer ${SHARED_KEY}`);
  assert.equal(String(seen.headers.authorization).includes(body.credential), false);
  assert.equal(seen.headers["x-hermes-session-key"], "iris:desktop:test");

  // Only the content type comes back; upstream headers are not reflected.
  assert.equal(response.headers.get("x-hermes-internal"), null);
  assert.equal(response.headers.get("cache-control"), "no-store");
  for (const value of response.headers.values()) {
    assert.equal(String(value).includes(SHARED_KEY), false);
  }
  assert.equal(JSON.stringify(link.logs).includes(SHARED_KEY), false);
});

test("every allowlisted route reaches upstream and unlisted ones do not", async (t) => {
  const upstream = await startFakeHermes((req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end("{}");
  });
  t.after(() => upstream.close());
  const link = await startLink({ hermesBaseUrl: upstream.baseUrl });
  t.after(() => link.close());
  const { body } = await pair(link);
  const auth = { Authorization: `Bearer ${body.credential}` };

  for (const route of HERMES_ROUTE_ALLOWLIST) {
    const concrete = route.pattern.replace(":id", "abc123");
    const response = await fetch(`${link.origin}/hermes${concrete}`, { method: route.method, headers: auth });
    await response.arrayBuffer();
    assert.equal(response.status, 200, `${route.method} ${concrete}`);
    assert.equal(upstream.seen.at(-1).url, concrete);
  }

  const before = upstream.seen.length;
  for (const [method, routePath] of [
    ["GET", "/hermes/v1/runs"],
    ["DELETE", "/hermes/v1/runs/abc"],
    ["POST", "/hermes/v1/runs/abc/cancel"],
    ["GET", "/hermes/api/sessions/abc/secrets"],
    ["GET", "/hermes/admin"],
    ["GET", "/hermes/"],
    ["GET", "/hermes"],
  ]) {
    const response = await fetch(`${link.origin}${routePath}`, { method, headers: auth });
    assert.equal(response.status, 403, `${method} ${routePath}`);
    assert.deepEqual(await response.json(), { error: "route_not_allowed" });
  }
  assert.equal(upstream.seen.length, before, "no unlisted request reached Hermes");
});

test("traversal and encoding tricks never reach upstream", async (t) => {
  const upstream = await startFakeHermes((req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end("{}");
  });
  t.after(() => upstream.close());
  const link = await startLink({ hermesBaseUrl: upstream.baseUrl });
  t.after(() => link.close());
  const { body } = await pair(link);
  const auth = { Authorization: `Bearer ${body.credential}` };

  for (const routePath of [
    "/hermes/v1/runs/abc/../../admin",
    "/hermes/v1/runs/..%2f..%2fadmin",
    "/hermes/v1/%2e%2e/admin",
    "/hermes/v1/runs/abc/events/../../../shutdown",
    "/hermes/v1/capabilities/../../v1/secrets",
    "/hermes/..%5cadmin",
  ]) {
    const response = await fetch(`${link.origin}${routePath}`, { headers: auth });
    assert.equal(response.status, 403, routePath);
    assert.deepEqual(await response.json(), { error: "route_not_allowed" });
  }
  assert.equal(upstream.seen.length, 0);
});

test("an SSE stream passes through incrementally and aborts upstream on disconnect", async (t) => {
  let upstreamRecord = null;
  const upstream = await startFakeHermes((req, res, record) => {
    upstreamRecord = record;
    res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
    res.write("data: {\"n\":1}\n\n");
    let n = 2;
    const timer = setInterval(() => {
      if (res.writableEnded) return;
      res.write(`data: {"n":${n}}\n\n`);
      n += 1;
    }, 25);
    res.on("close", () => clearInterval(timer));
  });
  t.after(() => upstream.close());
  const link = await startLink({ hermesBaseUrl: upstream.baseUrl });
  t.after(() => link.close());
  const { body } = await pair(link);

  const controller = new AbortController();
  const response = await fetch(`${link.origin}/hermes/v1/runs/run-1/events`, {
    headers: { Authorization: `Bearer ${body.credential}`, Accept: "text/event-stream" },
    signal: controller.signal,
  });
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /text\/event-stream/);

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const first = decoder.decode((await reader.read()).value);
  // Arrived before the upstream response ended: the proxy is not buffering.
  assert.match(first, /data: \{"n":1\}/);
  const second = decoder.decode((await reader.read()).value);
  assert.match(second, /data: \{"n":\d+\}/);

  controller.abort();
  await new Promise((resolve) => setTimeout(resolve, 500));
  assert.equal(upstreamRecord.aborted, true, "upstream stream should be aborted when the client leaves");
});

test("an unreachable Hermes is reported as agent_unreachable", async (t) => {
  const upstream = await startFakeHermes(() => {});
  const deadBaseUrl = upstream.baseUrl;
  await upstream.close();
  const link = await startLink({ hermesBaseUrl: deadBaseUrl });
  t.after(() => link.close());
  const { body } = await pair(link);

  const response = await fetch(`${link.origin}/hermes/v1/capabilities`, {
    headers: { Authorization: `Bearer ${body.credential}` },
  });
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: "agent_unreachable" });
});

test("oversized and non-JSON bodies are refused", async (t) => {
  const link = await startLink();
  t.after(() => link.close());
  const { body } = await pair(link);

  const huge = await fetch(`${link.origin}/hermes/v1/runs`, {
    method: "POST",
    headers: { Authorization: `Bearer ${body.credential}`, "Content-Type": "application/json" },
    body: JSON.stringify({ input: "x".repeat(70 * 1024) }),
  }).catch((error) => ({ status: 0, error }));
  assert.ok(huge.status === 413 || huge.status === 0, `expected a refusal, saw ${huge.status}`);

  const wrongType = await fetch(`${link.origin}/link/pair`, {
    method: "POST",
    headers: { "Content-Type": "text/plain" },
    body: "secret=1",
  });
  assert.equal(wrongType.status, 415);
  assert.deepEqual(await wrongType.json(), { error: "unsupported_media_type" });
});

test("unknown routes 404 for a paired device and never leak the shared key", async (t) => {
  const link = await startLink();
  t.after(() => link.close());
  const { body } = await pair(link);
  const auth = { Authorization: `Bearer ${body.credential}` };

  const notFound = await fetch(`${link.origin}/nope`, { headers: auth });
  assert.equal(notFound.status, 404);
  assert.deepEqual(await notFound.json(), { error: "not_found" });

  const wrongMethod = await fetch(`${link.origin}/link/status`, { method: "POST", headers: auth });
  assert.equal(wrongMethod.status, 405);

  assert.equal(JSON.stringify(link.logs).includes(SHARED_KEY), false);
});

test("credentials are compared without regard to a shared prefix", async (t) => {
  const link = await startLink();
  t.after(() => link.close());
  const { body } = await pair(link);

  for (const candidate of [
    body.credential.slice(0, -1),
    `${body.credential}${crypto.randomBytes(1).toString("hex")}`,
    body.credential.toUpperCase(),
  ]) {
    const response = await fetch(`${link.origin}/link/status`, {
      headers: { Authorization: `Bearer ${candidate}` },
    });
    assert.equal(response.status, 401);
    await response.arrayBuffer();
  }
});
