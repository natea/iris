import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { EventEmitter } from "node:events";
import {
  APNS_HOSTS,
  JWT_MIN_REGENERATE_MS,
  JWT_REFRESH_MS,
  buildApnsJwt,
  createApnsClient,
  isValidDeviceToken,
  maskDeviceToken,
  normalizeApnsEnvironment,
  resolveApnsConfig,
} from "../electron/apnsClient.mjs";

const TOKEN = "a".repeat(64);

// A stand-in for node:http2. Nothing here touches the network: the harness
// decides what Apple "answers" and records exactly what was sent.
class FakeStream extends EventEmitter {
  constructor(headers, session) {
    super();
    this.headers = headers;
    this.session = session;
    this.closedWith = null;
  }

  setTimeout(ms, cb) {
    this.timeoutMs = ms;
    this.timeoutCb = cb;
  }

  close(code) {
    this.closedWith = code;
  }

  end(body) {
    this.body = body ? Buffer.from(body).toString("utf8") : "";
    this.session.deliver(this);
  }
}

class FakeSession extends EventEmitter {
  constructor(host, harness) {
    super();
    this.host = host;
    this.harness = harness;
    this.closed = false;
    this.destroyed = false;
  }

  setTimeout() {}

  request(headers) {
    const stream = new FakeStream(headers, this);
    this.harness.streams.push(stream);
    return stream;
  }

  deliver(stream) {
    const reply = this.harness.replies.shift() || { status: 200 };
    if (reply.hang) return;
    setImmediate(() => {
      if (reply.streamError) {
        stream.emit("error", new Error("socket hangup"));
        return;
      }
      stream.emit("response", { ":status": reply.status });
      if (reply.body) stream.emit("data", Buffer.from(reply.body));
      stream.emit("end");
    });
  }

  close() {
    this.closed = true;
  }

  destroy() {
    this.destroyed = true;
  }
}

function harness(replies = []) {
  const state = { replies: [...replies], streams: [], sessions: [] };
  state.connect = (host) => {
    const session = new FakeSession(host, state);
    state.sessions.push(session);
    return session;
  };
  return state;
}

function testKeyPair() {
  return crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
}

function decodeJwt(jwt) {
  const [header, claims, signature] = jwt.split(".");
  return {
    header: JSON.parse(Buffer.from(header, "base64url").toString("utf8")),
    claims: JSON.parse(Buffer.from(claims, "base64url").toString("utf8")),
    signature,
    signingInput: `${header}.${claims}`,
  };
}

function makeClient(overrides = {}) {
  const { privateKey, publicKey } = overrides.keys || testKeyPair();
  const net = overrides.net || harness(overrides.replies || []);
  let clock = overrides.startAt ?? 1_000_000_000;
  const logs = [];
  let keyReads = 0;
  const client = createApnsClient({
    keyId: "2N9UJ67TPP",
    teamId: "YA3FM9C24T",
    topic: "app.iris.liveprototype",
    loadKey: () => {
      keyReads += 1;
      return privateKey;
    },
    now: () => clock,
    connect: net.connect,
    log: (message) => logs.push(message),
    ...overrides.inject,
  });
  return {
    client,
    net,
    logs,
    publicKey,
    keyReads: () => keyReads,
    advance: (ms) => {
      clock += ms;
    },
  };
}

test("the provider JWT has the shape APNs requires and a real P-256 signature", () => {
  const { privateKey, publicKey } = testKeyPair();
  const jwt = buildApnsJwt({
    keyId: "KEY123",
    teamId: "TEAM456",
    privateKey,
    issuedAt: 1_700_000_000,
  });
  const { header, claims, signature, signingInput } = decodeJwt(jwt);
  assert.deepEqual(header, { alg: "ES256", kid: "KEY123" });
  assert.deepEqual(claims, { iss: "TEAM456", iat: 1_700_000_000 });
  assert.equal(/[=+/]/.test(jwt), false, "the JWT must be base64url, not base64");
  // The signature must be the raw r||s pair Apple expects (64 bytes), and it
  // must verify against the public half of the key generated in this test.
  const raw = Buffer.from(signature, "base64url");
  assert.equal(raw.length, 64);
  assert.equal(
    crypto.verify("sha256", Buffer.from(signingInput), { key: publicKey, dsaEncoding: "ieee-p1363" }, raw),
    true,
  );
});

test("the JWT is reused for 50 minutes and never regenerated inside 20", async () => {
  const c = makeClient({ replies: [{ status: 200 }, { status: 200 }, { status: 200 }] });
  const first = c.client._providerToken();
  c.advance(19 * 60_000);
  assert.equal(c.client._providerToken(), first, "reused well inside the refresh window");
  // ExpiredProviderToken inside the regeneration floor cannot mint a new one.
  assert.equal(c.client._providerToken({ force: true }), first);
  c.advance(21 * 60_000);
  const forced = c.client._providerToken({ force: true });
  assert.notEqual(forced, first);
  assert.equal(c.keyReads(), 2);
  c.advance(JWT_REFRESH_MS + 1);
  assert.notEqual(c.client._providerToken(), forced, "refreshed once it is old enough");
  assert.ok(JWT_MIN_REGENERATE_MS < JWT_REFRESH_MS);
});

test("a send carries the exact path, headers and JSON body, to the right host", async () => {
  const c = makeClient({ replies: [{ status: 200 }] });
  const result = await c.client.send({
    deviceToken: TOKEN,
    environment: "sandbox",
    payload: { aps: { alert: { title: "Hermes finished" } }, run_id: "run-1", kind: "run_complete" },
    collapseId: "run-1",
    priority: 10,
    expiration: 0,
  });
  assert.deepEqual(result, { ok: true, status: 200, reason: "", unregistered: false });
  assert.equal(c.net.sessions.length, 1);
  assert.equal(c.net.sessions[0].host, APNS_HOSTS.sandbox);
  const [stream] = c.net.streams;
  assert.equal(stream.headers[":method"], "POST");
  assert.equal(stream.headers[":path"], `/3/device/${TOKEN}`);
  assert.equal(stream.headers["apns-topic"], "app.iris.liveprototype");
  assert.equal(stream.headers["apns-push-type"], "alert");
  assert.equal(stream.headers["apns-priority"], "10");
  assert.equal(stream.headers["apns-collapse-id"], "run-1");
  assert.equal(stream.headers["apns-expiration"], "0");
  assert.match(stream.headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.deepEqual(JSON.parse(stream.body), {
    aps: { alert: { title: "Hermes finished" } },
    run_id: "run-1",
    kind: "run_complete",
  });

  // Second send reuses the same HTTP/2 session, and production goes to the
  // production host.
  await c.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  assert.equal(c.net.sessions.length, 1);
});

test("production and sandbox use different Apple hosts", async () => {
  const c = makeClient({ replies: [{ status: 200 }] });
  await c.client.send({ deviceToken: TOKEN, environment: "production", payload: {} });
  assert.equal(c.net.sessions[0].host, APNS_HOSTS.production);
});

test("results are classified, and only dead tokens are marked unregistered", async () => {
  const c = makeClient({
    replies: [
      { status: 400, body: JSON.stringify({ reason: "BadDeviceToken" }) },
      { status: 410, body: JSON.stringify({ reason: "Unregistered" }) },
      { status: 400, body: JSON.stringify({ reason: "PayloadTooLarge" }) },
      { status: 400, body: JSON.stringify({ reason: "DeviceTokenNotForTopic" }) },
    ],
  });
  const bad = await c.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  assert.deepEqual(bad, { ok: false, status: 400, reason: "BadDeviceToken", unregistered: true });
  const gone = await c.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  assert.deepEqual(gone, { ok: false, status: 410, reason: "Unregistered", unregistered: true });
  const oversized = await c.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  assert.equal(oversized.unregistered, false, "a payload problem is not a dead token");
  const wrongTopic = await c.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  assert.equal(wrongTopic.unregistered, true);
});

test("an expired provider token is regenerated once and the push retried", async () => {
  const c = makeClient({
    replies: [{ status: 403, body: JSON.stringify({ reason: "ExpiredProviderToken" }) }, { status: 200 }],
  });
  c.client._providerToken();
  c.advance(JWT_MIN_REGENERATE_MS + 1);
  const result = await c.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  assert.equal(result.ok, true);
  assert.equal(c.net.streams.length, 2, "exactly one retry");
  assert.notEqual(
    c.net.streams[0].headers.authorization,
    c.net.streams[1].headers.authorization,
    "the retry uses a freshly minted JWT",
  );
  assert.equal(c.keyReads(), 2);
});

test("a 5xx and a connection error each get exactly one bounded retry", async () => {
  const transient = makeClient({ replies: [{ status: 503 }, { status: 200 }] });
  assert.equal((await transient.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} })).ok, true);
  assert.equal(transient.net.streams.length, 2);

  const broken = makeClient({ replies: [{ streamError: true }, { streamError: true }] });
  const result = await broken.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  assert.deepEqual(result, { ok: false, status: 0, reason: "stream_error", unregistered: false });
  assert.equal(broken.net.streams.length, 2, "never a retry loop");
});

test("a stream error drops the session so the next send reconnects", async () => {
  const c = makeClient({ replies: [{ streamError: true }, { streamError: true }, { status: 200 }] });
  await c.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  await c.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  assert.ok(c.net.sessions.length >= 2, "a dead session is not reused");
});

test("a GOAWAY retires the session", async () => {
  const c = makeClient({ replies: [{ status: 200 }, { status: 200 }] });
  await c.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  c.net.sessions[0].emit("goaway");
  await c.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  assert.equal(c.net.sessions.length, 2);
});

test("a hung request times out instead of hanging a caller forever", async () => {
  const net = harness([{ hang: true }, { hang: true }]);
  const c = makeClient({ net, inject: { requestTimeoutMs: 20 } });
  const pending = c.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  // The fake stream records the timeout the client asked for; fire it.
  await new Promise((resolve) => setTimeout(resolve, 5));
  for (const stream of net.streams) stream.timeoutCb?.();
  const settle = async () => {
    const result = await pending;
    return result;
  };
  const timer = setInterval(() => {
    for (const stream of net.streams) stream.timeoutCb?.();
  }, 5);
  const result = await settle();
  clearInterval(timer);
  assert.equal(result.ok, false);
  assert.equal(result.reason, "timeout");
});

test("malformed device tokens are refused before any request is made", async () => {
  const c = makeClient();
  for (const bad of ["", "zz".repeat(32), "abc", "a".repeat(63), `${TOKEN}a`, "a".repeat(400)]) {
    const result = await c.client.send({ deviceToken: bad, environment: "sandbox", payload: {} });
    assert.equal(result.ok, false);
    assert.equal(result.reason, "invalid_token");
  }
  assert.equal(c.net.streams.length, 0);
  assert.equal(isValidDeviceToken(TOKEN), true);
  assert.equal(isValidDeviceToken(TOKEN.toUpperCase()), true);
  assert.equal(isValidDeviceToken(`${TOKEN} `), true, "surrounding whitespace is trimmed");
  const unknownEnvironment = await c.client.send({ deviceToken: TOKEN, environment: "staging", payload: {} });
  assert.equal(unknownEnvironment.reason, "invalid_environment");
  assert.equal(normalizeApnsEnvironment("Production"), "production");
  assert.equal(normalizeApnsEnvironment("nope"), null);
});

test("no log line carries the key, the JWT, or a full device token", async () => {
  const c = makeClient({ replies: [{ status: 400, body: JSON.stringify({ reason: "BadDeviceToken" }) }] });
  await c.client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  const jwt = c.client._providerToken();
  assert.ok(c.logs.length >= 1);
  for (const line of c.logs) {
    assert.equal(line.includes(TOKEN), false);
    assert.equal(line.includes(jwt), false);
    assert.equal(line.includes("PRIVATE KEY"), false);
    assert.ok(line.includes(maskDeviceToken(TOKEN)));
  }
  assert.equal(maskDeviceToken(TOKEN).length, 8);
});

test("a missing key disables push instead of throwing", async () => {
  const net = harness();
  const client = createApnsClient({
    keyId: "K",
    teamId: "T",
    topic: "app.iris.liveprototype",
    loadKey: () => {
      throw new Error("ENOENT");
    },
    connect: net.connect,
  });
  const result = await client.send({ deviceToken: TOKEN, environment: "sandbox", payload: {} });
  assert.deepEqual(result, { ok: false, status: 0, reason: "key_unavailable", unregistered: false });
  assert.equal(net.streams.length, 0);

  const unconfigured = createApnsClient({ keyId: "", teamId: "", topic: "", loadKey: () => "x" });
  assert.equal((await unconfigured.send({ deviceToken: TOKEN, environment: "sandbox" })).reason, "not_configured");
});

test("config comes from env, or from exactly one ~/.iris/AuthKey_*.p8", () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "iris-apns-"));
  fs.mkdirSync(path.join(home, ".iris"));
  const env = { IRIS_APNS_TEAM_ID: "YA3FM9C24T" };

  assert.deepEqual(resolveApnsConfig({ env, homeDir: home }), { ok: false, reason: "no_key" });

  fs.writeFileSync(path.join(home, ".iris", "AuthKey_2N9UJ67TPP.p8"), "key");
  const derived = resolveApnsConfig({ env, homeDir: home });
  assert.equal(derived.ok, true);
  assert.equal(derived.keyId, "2N9UJ67TPP", "the key id is derived from the filename");
  assert.equal(derived.keyPath, path.join(home, ".iris", "AuthKey_2N9UJ67TPP.p8"));
  assert.equal(derived.topic, "app.iris.liveprototype");

  fs.writeFileSync(path.join(home, ".iris", "AuthKey_OTHER.p8"), "key");
  assert.deepEqual(resolveApnsConfig({ env, homeDir: home }), { ok: false, reason: "multiple_keys" });

  const explicit = resolveApnsConfig({
    env: { ...env, IRIS_APNS_KEY_PATH: "~/.iris/AuthKey_OTHER.p8", IRIS_APNS_TOPIC: "app.example" },
    homeDir: home,
  });
  assert.equal(explicit.ok, true);
  assert.equal(explicit.keyId, "OTHER");
  assert.equal(explicit.topic, "app.example");

  assert.deepEqual(resolveApnsConfig({ env: {}, homeDir: home, fsImpl: { readdirSync: () => ["AuthKey_A.p8"] } }), {
    ok: false,
    reason: "no_team_id",
  });
});

test("a Live Activity push uses the liveactivity topic, type and default priority", async () => {
  const h = makeClient({ replies: [{ status: 200 }] });
  const result = await h.client.send({
    deviceToken: TOKEN,
    environment: "sandbox",
    pushType: "liveactivity",
    payload: { aps: { timestamp: 1, event: "update", "content-state": { status: "running" } } },
  });

  assert.deepEqual(result, { ok: true, status: 200, reason: "", unregistered: false });
  const sent = h.net.streams[0];
  // Apple: "<your bundleID>.push-type.liveactivity".
  assert.equal(sent.headers["apns-topic"], "app.iris.liveprototype.push-type.liveactivity");
  assert.equal(sent.headers["apns-push-type"], "liveactivity");
  // Priority 5 is the budget-free one, so it is the default for an activity.
  assert.equal(sent.headers["apns-priority"], "5");
  assert.equal(sent.headers[":path"], `/3/device/${TOKEN}`);
  assert.equal(h.net.sessions[0].host, APNS_HOSTS.sandbox);
  assert.deepEqual(JSON.parse(sent.body).aps.event, "update");
});

test("a Live Activity push can be raised to priority 10, and the alert path is untouched", async () => {
  const h = makeClient({ replies: [{ status: 200 }, { status: 200 }] });
  await h.client.send({
    deviceToken: TOKEN,
    environment: "production",
    pushType: "liveactivity",
    priority: 10,
    payload: { aps: { event: "end" } },
  });
  assert.equal(h.net.streams[0].headers["apns-priority"], "10");

  await h.client.send({ deviceToken: TOKEN, environment: "production", payload: { aps: {} } });
  const alert = h.net.streams[1];
  assert.equal(alert.headers["apns-topic"], "app.iris.liveprototype");
  assert.equal(alert.headers["apns-push-type"], "alert");
  assert.equal(alert.headers["apns-priority"], "10");
});

test("an unknown push type and an oversized payload are refused without a request", async () => {
  const h = makeClient({ replies: [{ status: 200 }] });
  assert.deepEqual(await h.client.send({ deviceToken: TOKEN, environment: "sandbox", pushType: "voip" }), {
    ok: false,
    status: 0,
    reason: "invalid_push_type",
    unregistered: false,
  });
  const huge = { aps: { event: "update", "content-state": { headline: "x".repeat(5000) } } };
  assert.deepEqual(
    await h.client.send({ deviceToken: TOKEN, environment: "sandbox", pushType: "liveactivity", payload: huge }),
    { ok: false, status: 0, reason: "payload_too_large", unregistered: false },
  );
  assert.equal(h.net.streams.length, 0, "neither burned an APNs request");
});

test("a dead Live Activity token is reported as unregistered", async () => {
  const h = makeClient({ replies: [{ status: 410, body: JSON.stringify({ reason: "Unregistered" }) }] });
  const result = await h.client.send({
    deviceToken: TOKEN,
    environment: "sandbox",
    pushType: "liveactivity",
    payload: { aps: { event: "update" } },
  });
  assert.equal(result.unregistered, true);
  assert.equal(result.reason, "Unregistered");
  assert.equal(
    h.logs.some((line) => line.includes(TOKEN)),
    false,
    "a full token never reaches a log line",
  );
});
