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
    tasks: options.tasks,
    checkHermesReachable: options.checkHermesReachable,
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

// ===== High-level task API =====
//
// The handlers are injected, so these exercise the server's own contract:
// auth, validation, and the error code each failure maps to. The real
// handlers in main.mjs go through the desktop's own dispatch path.

// A fake desktop: a run registry with just enough behavior to observe origin,
// terminal status, and the announced handshake.
function fakeDesktop({ runs = [] } = {}) {
  const registry = new Map(runs.map((run) => [run.run_id, { ...run }]));
  const dispatched = [];
  return {
    registry,
    dispatched,
    tasks: {
      dispatch: async ({ task, urgency, deviceId }) => {
        if (task === "unreachable") throw new Error("connect ECONNREFUSED");
        if (task === "refused") return { error: "dispatch_failed", message: "Task is required." };
        const run = {
          run_id: `run-${dispatched.length + 1}`,
          task,
          status: "started",
          origin: `device:${deviceId}`,
          created_at: 1,
          updated_at: 1,
          announced_at: 0,
        };
        dispatched.push({ task, urgency, deviceId });
        registry.set(run.run_id, run);
        return { status: "started", run_id: run.run_id, message: "Hermes has started the task.", origin: run.origin };
      },
      list: ({ deviceId, undelivered }) =>
        [...registry.values()].filter((run) =>
          !undelivered ||
          (["completed", "failed"].includes(run.status) &&
            run.origin === `device:${deviceId}` &&
            !run.announced_at),
        ),
      get: async ({ runId }) => {
        const run = registry.get(runId);
        if (!run) return { error: "task_unknown" };
        return { ...run, instructions: "Hermes is still working." };
      },
      result: async ({ runId }) => {
        const run = registry.get(runId);
        if (!run) return { ok: false, error: "task_unknown" };
        if (!["completed", "failed"].includes(run.status)) {
          return { ok: false, error: "task_not_finished" };
        }
        return { ok: true, run_id: runId, task: run.task, status: run.status, output: run.output || "" };
      },
      stop: async ({ runId }) => {
        const run = registry.get(runId);
        if (!run) return { ok: false, error: "task_unknown" };
        run.status = "cancelled";
        return { status: "stopping" };
      },
      approve: async ({ runId, decision }) => {
        const run = registry.get(runId);
        if (!run) return { ok: false, error: "task_unknown" };
        if (!run.awaitingApproval) return { ok: false, error: "approval_not_pending" };
        run.decision = decision;
        return { ok: true };
      },
      markAnnounced: ({ runId }) => {
        const run = registry.get(runId);
        if (!run) return { ok: false, error: "task_unknown" };
        run.announced_at = 42;
        return { ok: true };
      },
    },
  };
}

async function linkFetch(link, credential, path, init = {}) {
  const response = await fetch(`${link.origin}${path}`, {
    ...init,
    headers: {
      ...(credential ? { Authorization: `Bearer ${credential}` } : {}),
      ...(init.body ? { "Content-Type": "application/json" } : {}),
      ...(init.headers || {}),
    },
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

test("every task route refuses an unpaired caller with not_paired", async (t) => {
  const desktop = fakeDesktop();
  const link = await startLink({ tasks: desktop.tasks });
  t.after(() => link.close());

  const calls = [
    ["POST", "/link/tasks", JSON.stringify({ task: "do a thing" })],
    ["GET", "/link/tasks", null],
    ["GET", "/link/tasks/run-1", null],
    ["GET", "/link/tasks/run-1/result", null],
    ["POST", "/link/tasks/run-1/stop", null],
    ["POST", "/link/tasks/run-1/approval", JSON.stringify({ decision: "once" })],
    ["POST", "/link/tasks/run-1/announced", null],
  ];
  for (const [method, path, body] of calls) {
    const result = await linkFetch(link, "", path, { method, body });
    assert.equal(result.status, 401, `${method} ${path}`);
    assert.deepEqual(result.body, { error: "not_paired" });
  }
  assert.equal(desktop.dispatched.length, 0);
});

test("a dispatched task records the device origin and returns a run id", async (t) => {
  const desktop = fakeDesktop();
  const link = await startLink({ tasks: desktop.tasks });
  t.after(() => link.close());
  const { body: paired } = await pair(link);

  const created = await linkFetch(link, paired.credential, "/link/tasks", {
    method: "POST",
    body: JSON.stringify({ task: "Summarize the repo", urgency: "high" }),
  });
  assert.equal(created.status, 200);
  assert.equal(created.body.status, "started");
  assert.equal(created.body.run_id, "run-1");
  assert.equal(created.body.origin, `device:${paired.deviceId}`);
  assert.deepEqual(desktop.dispatched, [
    { task: "Summarize the repo", urgency: "high", deviceId: paired.deviceId },
  ]);
});

test("dispatch validation is explicit and nothing reaches the agent", async (t) => {
  const desktop = fakeDesktop();
  const link = await startLink({ tasks: desktop.tasks });
  t.after(() => link.close());
  const { body: paired } = await pair(link);
  const post = (body) =>
    linkFetch(link, paired.credential, "/link/tasks", { method: "POST", body });

  assert.deepEqual(await post(JSON.stringify({})), { status: 400, body: { error: "task_required" } });
  assert.deepEqual(await post(JSON.stringify({ task: "   " })), {
    status: 400,
    body: { error: "task_required" },
  });
  assert.deepEqual(await post(JSON.stringify({ task: "x", urgency: "URGENT" })), {
    status: 400,
    body: { error: "invalid_urgency" },
  });
  assert.deepEqual(await post("not json"), { status: 400, body: { error: "invalid_json" } });
  assert.deepEqual(await post(JSON.stringify({ task: "x".repeat(20_001) })), {
    status: 400,
    body: { error: "task_too_long" },
  });
  assert.equal(desktop.dispatched.length, 0);

  const unreachable = await post(JSON.stringify({ task: "unreachable" }));
  assert.equal(unreachable.status, 502);
  assert.equal(unreachable.body.error, "agent_unreachable");
  const refused = await post(JSON.stringify({ task: "refused" }));
  assert.equal(refused.status, 502);
  assert.equal(refused.body.error, "dispatch_failed");
});

test("the task list includes desktop-dispatched runs", async (t) => {
  const desktop = fakeDesktop({
    runs: [
      {
        run_id: "desk-1",
        task: "Desktop work",
        status: "completed",
        origin: "desktop",
        created_at: 10,
        updated_at: 20,
        announced_at: 5,
      },
    ],
  });
  const link = await startLink({ tasks: desktop.tasks });
  t.after(() => link.close());
  const { body: paired } = await pair(link);

  await linkFetch(link, paired.credential, "/link/tasks", {
    method: "POST",
    body: JSON.stringify({ task: "Phone work" }),
  });
  const listed = await linkFetch(link, paired.credential, "/link/tasks");
  assert.equal(listed.status, 200);
  const byId = Object.fromEntries(listed.body.tasks.map((entry) => [entry.run_id, entry]));
  assert.equal(byId["desk-1"].origin, "desktop");
  assert.equal(byId["desk-1"].task, "Desktop work");
  assert.equal(byId["run-1"].origin, `device:${paired.deviceId}`);
  for (const key of ["run_id", "task", "status", "origin", "created_at", "updated_at"]) {
    assert.ok(key in byId["desk-1"], `list entries carry ${key}`);
  }
});

test("status and result are honest about unknown and unfinished runs", async (t) => {
  const desktop = fakeDesktop({
    runs: [
      { run_id: "run-live", task: "Working", status: "running", origin: "desktop", created_at: 1, updated_at: 2 },
      {
        run_id: "run-done",
        task: "Done",
        status: "completed",
        origin: "desktop",
        created_at: 1,
        updated_at: 3,
        output: "Three folders: a, b, c.",
      },
    ],
  });
  const link = await startLink({ tasks: desktop.tasks });
  t.after(() => link.close());
  const { body: paired } = await pair(link);
  const get = (path) => linkFetch(link, paired.credential, path);

  assert.deepEqual(await get("/link/tasks/nope"), { status: 404, body: { error: "task_unknown" } });
  assert.deepEqual(await get("/link/tasks/nope/result"), {
    status: 404,
    body: { error: "task_unknown" },
  });

  const live = await get("/link/tasks/run-live");
  assert.equal(live.status, 200);
  assert.equal(live.body.status, "running");
  assert.equal(live.body.run_id, "run-live");

  const early = await get("/link/tasks/run-live/result");
  assert.equal(early.status, 409);
  assert.deepEqual(early.body, { error: "task_not_finished" });

  const finished = await get("/link/tasks/run-done/result");
  assert.equal(finished.status, 200);
  assert.equal(finished.body.output, "Three folders: a, b, c.");
});

test("stop and approval refuse unknown runs and validate the decision", async (t) => {
  const desktop = fakeDesktop({
    runs: [
      { run_id: "run-1", task: "Working", status: "running", origin: "desktop", created_at: 1, updated_at: 2 },
      {
        run_id: "run-2",
        task: "Paused",
        status: "running",
        origin: "desktop",
        created_at: 1,
        updated_at: 2,
        awaitingApproval: true,
      },
    ],
  });
  const link = await startLink({ tasks: desktop.tasks });
  t.after(() => link.close());
  const { body: paired } = await pair(link);
  const post = (path, body) =>
    linkFetch(link, paired.credential, path, { method: "POST", body });

  assert.deepEqual(await post("/link/tasks/nope/stop"), {
    status: 404,
    body: { error: "task_unknown" },
  });
  const stopped = await post("/link/tasks/run-1/stop");
  assert.equal(stopped.status, 200);
  assert.equal(desktop.registry.get("run-1").status, "cancelled");

  assert.deepEqual(await post("/link/tasks/run-2/approval", JSON.stringify({ decision: "maybe" })), {
    status: 400,
    body: { error: "invalid_decision" },
  });
  const notPending = await post("/link/tasks/run-1/approval", JSON.stringify({ decision: "once" }));
  assert.equal(notPending.status, 409);
  assert.equal(notPending.body.error, "approval_not_pending");

  const approved = await post("/link/tasks/run-2/approval", JSON.stringify({ decision: "session" }));
  assert.equal(approved.status, 200);
  assert.equal(desktop.registry.get("run-2").decision, "session");
});

test("the undelivered/announced handshake never loses or repeats a completion", async (t) => {
  const desktop = fakeDesktop();
  const link = await startLink({ tasks: desktop.tasks });
  t.after(() => link.close());
  const { body: paired } = await pair(link);

  const created = await linkFetch(link, paired.credential, "/link/tasks", {
    method: "POST",
    body: JSON.stringify({ task: "Phone work" }),
  });
  const runId = created.body.run_id;
  desktop.registry.get(runId).status = "completed";

  const pendingBefore = await linkFetch(link, paired.credential, "/link/tasks?undelivered=1");
  assert.deepEqual(pendingBefore.body.tasks.map((entry) => entry.run_id), [runId]);

  // Still undelivered until the phone acknowledges it: a reconnect mid-
  // announcement must find it again.
  const stillPending = await linkFetch(link, paired.credential, "/link/tasks?undelivered=1");
  assert.deepEqual(stillPending.body.tasks.map((entry) => entry.run_id), [runId]);

  const acked = await linkFetch(link, paired.credential, `/link/tasks/${runId}/announced`, {
    method: "POST",
  });
  assert.deepEqual(acked, { status: 200, body: { ok: true, run_id: runId } });

  const after = await linkFetch(link, paired.credential, "/link/tasks?undelivered=1");
  assert.deepEqual(after.body.tasks, []);
  assert.deepEqual(await linkFetch(link, paired.credential, "/link/tasks/nope/announced", { method: "POST" }), {
    status: 404,
    body: { error: "task_unknown" },
  });
});

test("task routes refuse the wrong method and unknown actions", async (t) => {
  const desktop = fakeDesktop();
  const link = await startLink({ tasks: desktop.tasks });
  t.after(() => link.close());
  const { body: paired } = await pair(link);

  const deleteList = await linkFetch(link, paired.credential, "/link/tasks", { method: "DELETE" });
  assert.equal(deleteList.status, 405);
  const postOne = await linkFetch(link, paired.credential, "/link/tasks/run-1", { method: "POST" });
  assert.equal(postOne.status, 405);
  const bogus = await linkFetch(link, paired.credential, "/link/tasks/run-1/launch", { method: "POST" });
  assert.equal(bogus.status, 404);
  const deep = await linkFetch(link, paired.credential, "/link/tasks/run-1/result/extra");
  assert.equal(deep.status, 404);
});

test("without injected handlers the task API says so rather than pretending", async (t) => {
  const link = await startLink();
  t.after(() => link.close());
  const { body: paired } = await pair(link);
  const listed = await linkFetch(link, paired.credential, "/link/tasks");
  assert.deepEqual(listed, { status: 501, body: { error: "tasks_unavailable" } });
});

test("/link/status reports Hermes reachability freshly, then briefly caches it", async (t) => {
  let reachable = false;
  let probes = 0;
  const link = await startLink({
    getInfo: () => ({ hermesReachable: true, userName: "Nate", liveModel: "m", voice: "Zephyr", accent: "" }),
    checkHermesReachable: async () => {
      probes += 1;
      return reachable;
    },
  });
  t.after(() => link.close());
  const { body: paired } = await pair(link);

  // The cached getInfo() flag said "reachable"; the live probe is what counts.
  const first = await linkFetch(link, paired.credential, "/link/status");
  assert.equal(first.body.hermesReachable, false);
  assert.equal(probes, 1);

  reachable = true;
  const second = await linkFetch(link, paired.credential, "/link/status");
  assert.equal(second.body.hermesReachable, false, "answers from the short cache");
  assert.equal(probes, 1);
});

test("/link/status falls back to the reported flag when no probe is injected", async (t) => {
  const link = await startLink({
    getInfo: () => ({ hermesReachable: true, userName: "Nate", liveModel: "m", voice: "Zephyr", accent: "" }),
  });
  t.after(() => link.close());
  const { body: paired } = await pair(link);
  const status = await linkFetch(link, paired.credential, "/link/status");
  assert.equal(status.body.hermesReachable, true);
});

test("a hung Hermes probe cannot hang a status request", async (t) => {
  const link = await startLink({
    getInfo: () => ({ hermesReachable: false, userName: "Nate", liveModel: "m", voice: "Zephyr", accent: "" }),
    checkHermesReachable: () => new Promise(() => {}),
  });
  t.after(() => link.close());
  const { body: paired } = await pair(link);
  const started = Date.now();
  const status = await linkFetch(link, paired.credential, "/link/status");
  assert.equal(status.status, 200);
  assert.equal(status.body.hermesReachable, false);
  assert.ok(Date.now() - started < 5_000, "the probe is time-bounded");
});

test("an authenticated device reports a fresh last-seen immediately", async (t) => {
  const link = await startLink();
  t.after(() => link.close());
  const { body: paired } = await pair(link);
  const pairedAt = link.store.listDevices()[0].lastSeenAt;

  await new Promise((resolve) => setTimeout(resolve, 5));
  await linkFetch(link, paired.credential, "/link/status");

  const [device] = link.store.listDevices();
  assert.ok(
    device.lastSeenAt > pairedAt,
    "the Settings list must not say 'never' for a device that just called",
  );
});
