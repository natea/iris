import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { HermesGatewayClient } from "../electron/hermesGatewayClient.mjs";

class FakeChild extends EventEmitter {
  constructor() {
    super();
    this.stdout = new PassThrough();
    this.stderr = new PassThrough();
    this.exitCode = null;
  }

  kill() {
    if (this.exitCode != null) return;
    this.exitCode = 0;
    this.emit("exit", 0, null);
  }
}

class FakeWebSocket extends EventTarget {
  static OPEN = 1;
  static instances = [];

  constructor(url) {
    super();
    this.url = url;
    this.readyState = 0;
    FakeWebSocket.instances.push(this);
    setImmediate(() => {
      this.readyState = FakeWebSocket.OPEN;
      this.dispatchEvent(new Event("open"));
      this.dispatchEvent(
        new MessageEvent("message", {
          data: JSON.stringify({
            jsonrpc: "2.0",
            method: "event",
            params: { type: "gateway.ready", payload: {} },
          }),
        }),
      );
    });
  }

  send(raw) {
    const request = JSON.parse(raw);
    setImmediate(() => {
      this.dispatchEvent(
        new MessageEvent("message", {
          data: JSON.stringify({
            jsonrpc: "2.0",
            id: request.id,
            result: { method: request.method, ok: true },
          }),
        }),
      );
    });
  }

  close() {
    this.readyState = 3;
  }
}

test("spawns hermes serve, authenticates the socket, and correlates RPC responses", async () => {
  const child = new FakeChild();
  const spawnImpl = (_command, args, options) => {
    assert.deepEqual(args.slice(-5), ["serve", "--host", "127.0.0.1", "--port", "0"]);
    assert.ok(options.env.HERMES_DASHBOARD_SESSION_TOKEN);
    assert.equal("TERMINAL_CWD" in options.env, false);
    setImmediate(() => child.stdout.write("HERMES_BACKEND_READY port=43210\n"));
    return child;
  };
  const client = new HermesGatewayClient({
    candidates: () => [{ cmd: "hermes", args: [] }],
    WebSocketImpl: FakeWebSocket,
    spawnImpl,
    env: {},
    startupTimeoutMs: 1000,
  });
  await client.start();
  assert.match(FakeWebSocket.instances[0].url, /^ws:\/\/127\.0\.0\.1:43210\/api\/ws\?token=/);
  const result = await client.request("session.create", { source: "iris" });
  assert.deepEqual(result, { method: "session.create", ok: true });
  client.close();
});

test("the startup allowance is generous by default and back-off is exponential", async () => {
  const { DEFAULT_STARTUP_TIMEOUT_MS, startBackoffMs } = await import(
    "../electron/hermesGatewayClient.mjs"
  );
  // Well above the ~4–9 s a healthy `hermes serve` takes, because one slow
  // MCP server pushed a real start past the old allowance.
  assert.ok(DEFAULT_STARTUP_TIMEOUT_MS >= 60_000);
  assert.equal(startBackoffMs(0), 0);
  assert.equal(startBackoffMs(1), 2_000);
  assert.equal(startBackoffMs(2), 4_000);
  assert.equal(startBackoffMs(3), 8_000);
  assert.equal(startBackoffMs(20), 60_000);
});

test("a backend that will not start backs off instead of respawning in a loop", async () => {
  let spawns = 0;
  let clock = 0;
  const client = new HermesGatewayClient({
    candidates: () => [{ cmd: "hermes", args: [] }],
    spawnImpl: () => {
      spawns += 1;
      const child = new FakeChild();
      setImmediate(() => {
        child.stderr.write("MCP server 'strava' failed to authenticate: OAuth token expired (401)\n");
        child.exitCode = 1;
        child.emit("exit", 1, null);
      });
      return child;
    },
    WebSocketImpl: FakeWebSocket,
    startupTimeoutMs: 50,
    now: () => clock,
  });

  const first = await client.start().then(() => null, (error) => error);
  assert.ok(first, "the first start fails");
  assert.equal(spawns, 1);
  // The real cause travels with the error, so it can be classified.
  assert.match(first.logTail, /strava/);

  // A second attempt inside the window does NOT respawn, and reports the same
  // real failure rather than an invented "backing off" one.
  const second = await client.start().then(() => null, (error) => error);
  assert.equal(spawns, 1);
  assert.equal(second, first);

  // Once the window passes, one more attempt is allowed.
  clock += 5_000;
  await client.start().then(() => null, () => null);
  assert.equal(spawns, 2);
  client.close({ force: true });
});
