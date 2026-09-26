import test from "node:test";
import assert from "node:assert/strict";
import {
  DISMISSAL_COMPLETED_MS,
  DISMISSAL_UNHAPPY_MS,
  LIVE_ACTIVITY_ATTRIBUTES_TYPE,
  LIVE_ACTIVITY_MIN_INTERVAL_MS,
  LIVE_ACTIVITY_STALE_MS,
  MAX_SUMMARY_RUNS,
  PUSH_TO_START_GRACE_MS,
  buildContentState,
  buildEndPayload,
  buildStartPayload,
  buildUpdatePayload,
  createLiveActivityNotifier,
  fitPayload,
} from "../electron/liveActivityNotifier.mjs";
import { APNS_MAX_PAYLOAD_BYTES } from "../electron/apnsClient.mjs";

const START_TOKEN = "1".repeat(64);
const UPDATE_TOKEN = "2".repeat(64);

function runView(overrides = {}) {
  return {
    runId: "run-1",
    title: "Summarize the quarterly numbers",
    status: "running",
    origin: "device:phone-1",
    headline: "Running code",
    detail: "python analyze.py",
    stepCount: 3,
    stepsKnown: true,
    startedAt: 1_700_000_000_000,
    updatedAt: 1_700_000_010_000,
    pendingApproval: null,
    ...overrides,
  };
}

// A harness with no network, no Electron and a clock the test owns.
function makeNotifier(overrides = {}) {
  let clock = overrides.startAt ?? 1_700_000_000_000;
  const sends = [];
  const logs = [];
  const dropped = { activities: [], startTokens: [] };
  const timers = [];
  let snapshot = overrides.snapshot || { activeRuns: [], lastFinished: null };
  let devices = overrides.devices || {
    "phone-1": {
      deviceId: "phone-1",
      startToken: { token: START_TOKEN, environment: "sandbox" },
      activities: [{ activityId: "ACT-1", token: UPDATE_TOKEN, environment: "sandbox" }],
    },
  };
  const client = {
    send: async (request) => {
      sends.push(request);
      const reply = overrides.replies?.shift();
      return reply || { ok: true, status: 200, reason: "", unregistered: false };
    },
  };
  const notifier = createLiveActivityNotifier({
    getClient: () => (overrides.unconfigured ? null : client),
    getSnapshot: () => snapshot,
    getDeviceIds: () => Object.keys(devices),
    getTargets: (deviceId) => devices[deviceId] || null,
    getAttributes: (deviceId) => ({ title: "Hermes", macName: "studio", deviceId }),
    dropActivity: (deviceId, activityId) => {
      dropped.activities.push([deviceId, activityId]);
      const device = devices[deviceId];
      if (device) {
        device.activities = device.activities.filter((a) => a.activityId !== activityId);
      }
    },
    dropStartToken: (deviceId) => {
      dropped.startTokens.push(deviceId);
      if (devices[deviceId]) devices[deviceId].startToken = null;
    },
    log: (message, level) => logs.push({ message, level }),
    now: () => clock,
    schedule: (fn, ms) => {
      const timer = { fn, ms, cancelled: false };
      timers.push(timer);
      return timer;
    },
    clear: (timer) => {
      if (timer) timer.cancelled = true;
    },
    ...overrides.inject,
  });
  return {
    notifier,
    sends,
    logs,
    dropped,
    timers,
    devices,
    advance: (ms) => {
      clock += ms;
    },
    setSnapshot: (next) => {
      snapshot = next;
    },
    // Run whatever trailing flush is armed, as the event loop would.
    runTimers: async () => {
      const pending = timers.filter((timer) => !timer.cancelled);
      timers.length = 0;
      for (const timer of pending) timer.fn();
      await notifier.settled();
    },
  };
}

const state = (payload) => payload.aps["content-state"];

test("the content state is built only from real run data, never invented progress", () => {
  const built = buildContentState(
    {
      activeRuns: [runView(), runView({ runId: "run-2", title: "Book a table", updatedAt: 1 })],
      lastFinished: null,
    },
    { at: 1_700_000_020_000 },
  );

  assert.equal(built.status, "running");
  assert.equal(built.headline, "Running code");
  assert.equal(built.title, "Summarize the quarterly numbers");
  assert.equal(built.stepCount, 3);
  assert.equal(built.stepsKnown, true);
  assert.equal(built.activeRunCount, 2);
  assert.equal(built.needsAttention, false);
  assert.equal(built.attentionSummary, "");
  // Epoch SECONDS as a Double, so a default Swift JSONDecoder cannot misread it.
  assert.equal(built.updatedAt, 1_700_000_020);
  assert.equal(built.startedAt, 1_700_000_000);
  assert.deepEqual(built.runs.map((run) => run.id), ["run-1", "run-2"]);
  // The exact contract the Swift ContentState must decode (LINK_API.md §14.2).
  // Hermes reports no percentages and no ETA, so there is no field for one:
  // adding one here would be inventing progress.
  assert.deepEqual(Object.keys(built), [
    "status",
    "headline",
    "title",
    "detail",
    "stepCount",
    "stepsKnown",
    "activeRunCount",
    "needsAttention",
    "attentionSummary",
    "runs",
    "startedAt",
    "updatedAt",
  ]);
  assert.deepEqual(Object.keys(built.runs[0]), ["id", "title", "status", "headline"]);
});

test("unknown steps say so rather than claiming zero, and the run list is capped", () => {
  const built = buildContentState({
    activeRuns: [
      runView({ stepsKnown: false, stepCount: 9, headline: "" }),
      runView({ runId: "b" }),
      runView({ runId: "c" }),
      runView({ runId: "d" }),
      runView({ runId: "e" }),
    ],
    lastFinished: null,
  });
  // The primary is the most recently updated; they all share updatedAt here,
  // so assert on the shape that matters: a false stepsKnown zeroes the count.
  const unknown = buildContentState({
    activeRuns: [runView({ stepsKnown: false, stepCount: 9 })],
    lastFinished: null,
  });
  assert.equal(unknown.stepsKnown, false);
  assert.equal(unknown.stepCount, 0, "an unknown history is never reported as zero work");
  assert.equal(built.runs.length, MAX_SUMMARY_RUNS);
  assert.equal(built.activeRunCount, 5, "the count is still the truth");
});

test("an idle state reports the real terminal status of the last run", () => {
  const done = buildContentState({ activeRuns: [], lastFinished: { runId: "r", title: "T", status: "completed" } });
  assert.equal(done.status, "done");
  assert.equal(done.headline, "");
  assert.equal(done.title, "T");

  assert.equal(buildContentState({ activeRuns: [], lastFinished: { status: "failed" } }).status, "failed");
  assert.equal(buildContentState({ activeRuns: [], lastFinished: { status: "error" } }).status, "failed");
  assert.equal(buildContentState({ activeRuns: [], lastFinished: { status: "cancelled" } }).status, "stopped");
  assert.equal(buildContentState({ activeRuns: [], lastFinished: null }).status, "idle");
});

test("a pending approval wins the primary slot and flags attention", () => {
  const built = buildContentState({
    activeRuns: [
      runView({ runId: "busy", updatedAt: 9_999_999_999_999 }),
      runView({
        runId: "blocked",
        title: "Deploy the site",
        updatedAt: 1,
        pendingApproval: { summary: "Hermes wants to run: rm -rf build" },
      }),
    ],
    lastFinished: null,
  });
  assert.equal(built.status, "waiting");
  assert.equal(built.needsAttention, true);
  assert.equal(built.title, "Deploy the site");
  assert.equal(built.attentionSummary, "Hermes wants to run: rm -rf build");
});

test("payloads carry the exact aps keys Apple documents", () => {
  const built = buildContentState({ activeRuns: [runView()], lastFinished: null }, { at: 2_000_000_000_000 });

  const update = buildUpdatePayload({ state: built, at: 2_000_000_000_000 });
  assert.deepEqual(Object.keys(update.aps).sort(), [
    "content-state",
    "event",
    "relevance-score",
    "stale-date",
    "timestamp",
  ]);
  assert.equal(update.aps.event, "update");
  assert.equal(update.aps.timestamp, 2_000_000_000);
  assert.equal(update.aps["stale-date"], (2_000_000_000_000 + LIVE_ACTIVITY_STALE_MS) / 1000);

  const start = buildStartPayload({ state: built, attributes: { title: "Hermes" }, at: 2_000_000_000_000 });
  assert.equal(start.aps.event, "start");
  assert.equal(start.aps["attributes-type"], LIVE_ACTIVITY_ATTRIBUTES_TYPE);
  assert.deepEqual(start.aps.attributes, { title: "Hermes" });
  assert.equal(start.aps["input-push-token"], 1);
  // Apple requires an alert on a start payload.
  assert.ok(start.aps.alert?.title);

  const end = buildEndPayload({ state: { ...built, status: "done" }, at: 2_000_000_000_000 });
  assert.equal(end.aps.event, "end");
  assert.equal(end.aps["dismissal-date"], (2_000_000_000_000 + DISMISSAL_COMPLETED_MS) / 1000);
  assert.equal(end.aps["stale-date"], undefined, "an ended activity cannot go stale");
  const failed = buildEndPayload({ state: { ...built, status: "failed" }, at: 2_000_000_000_000 });
  assert.equal(failed.aps["dismissal-date"], (2_000_000_000_000 + DISMISSAL_UNHAPPY_MS) / 1000);
});

test("an oversized payload sheds optional detail until it fits Apple's 4 KB limit", () => {
  const built = buildContentState(
    {
      activeRuns: Array.from({ length: 3 }, (_, index) =>
        runView({
          runId: `run-${index}`,
          title: "t".repeat(400),
          headline: "h".repeat(400),
          detail: "d".repeat(400),
        }),
      ),
      lastFinished: null,
    },
    { at: 1 },
  );
  const fitted = fitPayload(buildUpdatePayload({ state: built, at: 1 }), { budget: 400 });
  assert.ok(Buffer.byteLength(JSON.stringify(fitted), "utf8") < APNS_MAX_PAYLOAD_BYTES);
  // The counts and the status survive; the list is what gets dropped.
  assert.equal(state(fitted).activeRunCount, 3);
  assert.equal(state(fitted).status, "running");
});

test("bursts of events coalesce into one push, with a trailing flush carrying the latest state", async () => {
  const h = makeNotifier();
  h.setSnapshot({ activeRuns: [runView({ headline: "Running code" })], lastFinished: null });

  h.notifier.noteChange();
  await h.notifier.settled();
  assert.equal(h.sends.length, 1, "the first change pushes immediately");
  assert.equal(state(h.sends[0].payload).headline, "Running code");

  // Ten events inside the window produce no further pushes.
  for (let index = 0; index < 10; index += 1) {
    h.advance(200);
    h.setSnapshot({ activeRuns: [runView({ headline: `Searching host-${index}.com` })], lastFinished: null });
    h.notifier.noteChange();
  }
  assert.equal(h.sends.length, 1, "Hermes' firehose does not become ten APNs requests");

  // The trailing flush lands, and it carries the LAST state, not the first.
  h.advance(LIVE_ACTIVITY_MIN_INTERVAL_MS);
  await h.runTimers();
  assert.equal(h.sends.length, 2);
  assert.equal(state(h.sends[1].payload).headline, "Searching host-9.com");
  // Routine progress is priority 5: the budget-free one.
  assert.equal(h.sends[1].priority, 5);
  assert.equal(h.sends[1].pushType, "liveactivity");
});

test("an unchanged state costs nothing", async () => {
  const h = makeNotifier();
  h.setSnapshot({ activeRuns: [runView()], lastFinished: null });
  h.notifier.noteChange();
  await h.notifier.settled();
  assert.equal(h.sends.length, 1);

  h.advance(LIVE_ACTIVITY_MIN_INTERVAL_MS * 3);
  // Same run, same headline, same counts — only the wall clock moved.
  h.notifier.noteChange();
  await h.notifier.settled();
  assert.equal(h.sends.length, 1, "the clock alone is not news");
});

test("an approval appearing jumps the coalescing window at priority 10 with an alert", async () => {
  const h = makeNotifier();
  h.setSnapshot({ activeRuns: [runView()], lastFinished: null });
  h.notifier.noteChange();
  await h.notifier.settled();

  h.advance(500);
  h.setSnapshot({
    activeRuns: [runView({ pendingApproval: { summary: "Hermes wants to run: rm -rf build" } })],
    lastFinished: null,
  });
  h.notifier.noteChange();
  await h.notifier.settled();

  assert.equal(h.sends.length, 2, "a human being asked for something does not wait out the window");
  assert.equal(h.sends[1].priority, 10);
  assert.equal(state(h.sends[1].payload).needsAttention, true);
  assert.equal(h.sends[1].payload.aps.alert.title, "Hermes needs you");
  assert.equal(h.sends[1].payload.aps["relevance-score"], 100);

  // Clearing it is ordinary news: no alert, and it waits for the window.
  h.advance(500);
  h.setSnapshot({ activeRuns: [runView()], lastFinished: null });
  h.notifier.noteChange();
  await h.notifier.settled();
  assert.equal(h.sends.length, 2);
  h.advance(LIVE_ACTIVITY_MIN_INTERVAL_MS);
  await h.runTimers();
  assert.equal(h.sends.length, 3);
  assert.equal(state(h.sends[2].payload).needsAttention, false);
  assert.equal(h.sends[2].payload.aps.alert, undefined);
});

test("the terminal end is always sent, with the real status, immediately", async () => {
  for (const [status, expected, dismissAfter] of [
    ["completed", "done", DISMISSAL_COMPLETED_MS],
    ["failed", "failed", DISMISSAL_UNHAPPY_MS],
    ["cancelled", "stopped", DISMISSAL_UNHAPPY_MS],
  ]) {
    const h = makeNotifier();
    h.setSnapshot({ activeRuns: [runView()], lastFinished: null });
    h.notifier.noteChange();
    await h.notifier.settled();

    // The run finishes one millisecond into the coalescing window.
    h.advance(1);
    h.setSnapshot({
      activeRuns: [],
      lastFinished: { runId: "run-1", title: "Summarize the quarterly numbers", status },
    });
    h.notifier.noteChange();
    await h.notifier.settled();

    const last = h.sends.at(-1);
    assert.equal(h.sends.length, 2, `${status}: the end is never coalesced away`);
    assert.equal(last.payload.aps.event, "end");
    assert.equal(state(last.payload).status, expected, "the real terminal status, never an optimistic default");
    assert.equal(last.priority, 10);
    assert.equal(
      last.payload.aps["dismissal-date"] * 1000 - last.payload.aps.timestamp * 1000,
      dismissAfter,
    );
    // The activity is over: its update token is forgotten.
    assert.deepEqual(h.dropped.activities, [["phone-1", "ACT-1"]]);
    assert.deepEqual(h.devices["phone-1"].activities, []);
  }
});

test("every non-terminal push advances the stale date so an offline Mac cannot lie", async () => {
  const h = makeNotifier();
  h.setSnapshot({ activeRuns: [runView()], lastFinished: null });
  h.notifier.noteChange();
  await h.notifier.settled();
  const first = h.sends[0].payload.aps["stale-date"];

  h.advance(LIVE_ACTIVITY_MIN_INTERVAL_MS);
  h.setSnapshot({ activeRuns: [runView({ headline: "Browsing example.com" })], lastFinished: null });
  h.notifier.noteChange();
  await h.notifier.settled();

  assert.ok(h.sends[1].payload.aps["stale-date"] > first, "the stale date moves forward with each push");
  assert.equal(
    h.sends[1].payload.aps["stale-date"] - h.sends[1].payload.aps.timestamp,
    LIVE_ACTIVITY_STALE_MS / 1000,
  );
});

test("push-to-start fires only when the device has a start token and no activity", async () => {
  const h = makeNotifier();
  h.setSnapshot({ activeRuns: [runView()], lastFinished: null });

  // It already has a live activity: an update carries the new run.
  assert.deepEqual(await h.notifier.noteDeviceRunStarted({ deviceId: "phone-1" }), {
    skipped: "already_live",
  });
  assert.equal(h.sends.length, 0);

  h.devices["phone-1"].activities = [];
  const started = await h.notifier.noteDeviceRunStarted({ deviceId: "phone-1" });
  assert.equal(started.sent, true);
  assert.equal(h.sends[0].payload.aps.event, "start");
  assert.equal(h.sends[0].payload.aps["attributes-type"], LIVE_ACTIVITY_ATTRIBUTES_TYPE);
  assert.deepEqual(h.sends[0].payload.aps.attributes, {
    title: "Hermes",
    macName: "studio",
    deviceId: "phone-1",
  });
  assert.equal(h.sends[0].deviceToken, START_TOKEN);
  assert.equal(h.sends[0].priority, 10);

  // A second run inside the grace window must not start a second activity
  // while the phone is still registering the first one's token.
  h.advance(PUSH_TO_START_GRACE_MS - 1);
  assert.deepEqual(await h.notifier.noteDeviceRunStarted({ deviceId: "phone-1" }), {
    skipped: "start_pending",
  });
  assert.equal(h.sends.length, 1);

  // With no start token at all, the app has to start it locally.
  h.devices["phone-1"].startToken = null;
  h.advance(PUSH_TO_START_GRACE_MS);
  assert.deepEqual(await h.notifier.noteDeviceRunStarted({ deviceId: "phone-1" }), {
    skipped: "no_start_token",
  });
  assert.deepEqual(await h.notifier.noteDeviceRunStarted({ deviceId: "unknown" }), {
    skipped: "no_start_token",
  });
});

test("a desktop-origin run never starts an activity but does appear in one that exists", async () => {
  const h = makeNotifier();
  h.devices["phone-1"].activities = [];
  // Nothing calls noteDeviceRunStarted for a desktop run, and a plain change
  // must not push-to-start on its own.
  h.setSnapshot({ activeRuns: [runView({ origin: "desktop" })], lastFinished: null });
  h.notifier.noteChange();
  await h.notifier.settled();
  assert.equal(h.sends.length, 0, "no activity token, so nothing to update, and no uninvited start");

  // Once the phone has an activity, the desktop's own run shows up in it: the
  // question is "what is Hermes doing", not "what did this phone ask for".
  h.devices["phone-1"].activities = [
    { activityId: "ACT-9", token: UPDATE_TOKEN, environment: "sandbox" },
  ];
  h.advance(LIVE_ACTIVITY_MIN_INTERVAL_MS);
  h.setSnapshot({ activeRuns: [runView({ origin: "desktop", headline: "Working on plan.md" })], lastFinished: null });
  h.notifier.noteChange();
  await h.notifier.settled();
  assert.equal(h.sends.length, 1);
  assert.equal(state(h.sends[0].payload).headline, "Working on plan.md");
});

test("nothing is pushed and nothing throws when push is unconfigured", async () => {
  const h = makeNotifier({ unconfigured: true });
  h.setSnapshot({ activeRuns: [runView()], lastFinished: null });
  h.notifier.noteChange();
  await h.notifier.settled();
  h.advance(LIVE_ACTIVITY_MIN_INTERVAL_MS * 5);
  h.setSnapshot({ activeRuns: [], lastFinished: { status: "completed" } });
  h.notifier.noteChange();
  await h.notifier.settled();
  assert.deepEqual(await h.notifier.noteDeviceRunStarted({ deviceId: "phone-1" }), {
    skipped: "not_configured",
  });

  assert.equal(h.sends.length, 0);
  assert.equal(h.logs.filter((entry) => entry.message.includes("not configured")).length, 1);
});

test("a token Apple rejects is dropped and not used again", async () => {
  const h = makeNotifier({
    replies: [{ ok: false, status: 410, reason: "Unregistered", unregistered: true }],
  });
  h.setSnapshot({ activeRuns: [runView()], lastFinished: null });
  h.notifier.noteChange();
  await h.notifier.settled();

  assert.deepEqual(h.dropped.activities, [["phone-1", "ACT-1"]]);
  assert.deepEqual(h.devices["phone-1"].activities, []);

  h.advance(LIVE_ACTIVITY_MIN_INTERVAL_MS);
  h.setSnapshot({ activeRuns: [runView({ headline: "Browsing example.com" })], lastFinished: null });
  h.notifier.noteChange();
  await h.notifier.settled();
  assert.equal(h.sends.length, 1, "the dead token is never pushed to again");
});

test("a rejected push-to-start token is dropped too", async () => {
  const h = makeNotifier({
    replies: [{ ok: false, status: 400, reason: "BadDeviceToken", unregistered: true }],
  });
  h.devices["phone-1"].activities = [];
  h.setSnapshot({ activeRuns: [runView()], lastFinished: null });
  await h.notifier.noteDeviceRunStarted({ deviceId: "phone-1" });
  assert.deepEqual(h.dropped.startTokens, ["phone-1"]);
  assert.equal(h.devices["phone-1"].startToken, null);
});

test("a broken snapshot or device list degrades to silence, never an exception", async () => {
  const h = makeNotifier({
    inject: {
      getSnapshot: () => {
        throw new Error("registry exploded");
      },
    },
  });
  h.notifier.noteChange();
  await h.notifier.settled();
  assert.equal(h.sends.length, 0);

  const g = makeNotifier({
    inject: {
      getDeviceIds: () => {
        throw new Error("store exploded");
      },
    },
  });
  g.setSnapshot({ activeRuns: [runView()], lastFinished: null });
  g.notifier.noteChange();
  await g.notifier.settled();
  assert.equal(g.sends.length, 0);
});

test("flush pushes the current state regardless of the window, and stop disarms the timer", async () => {
  const h = makeNotifier();
  h.setSnapshot({ activeRuns: [runView()], lastFinished: null });
  h.notifier.noteChange();
  await h.notifier.settled();

  h.advance(100);
  h.setSnapshot({ activeRuns: [runView({ headline: "Searching example.com" })], lastFinished: null });
  h.notifier.noteChange();
  assert.equal(h.sends.length, 1, "it is inside the window");

  await h.notifier.flush();
  assert.equal(h.sends.length, 2);
  assert.equal(state(h.sends[1].payload).headline, "Searching example.com");
  assert.equal(h.timers.every((timer) => timer.cancelled), true, "flush cancels the armed flush");

  h.advance(100);
  h.setSnapshot({ activeRuns: [runView({ headline: "Thinking…" })], lastFinished: null });
  h.notifier.noteChange();
  h.notifier.stop();
  assert.equal(h.timers.filter((timer) => !timer.cancelled).length, 0);
});

test("the same state is fanned out to every device that is showing it", async () => {
  const h = makeNotifier({
    devices: {
      "phone-1": {
        startToken: null,
        activities: [{ activityId: "A", token: UPDATE_TOKEN, environment: "sandbox" }],
      },
      "ipad-2": {
        startToken: null,
        activities: [{ activityId: "B", token: START_TOKEN, environment: "production" }],
      },
      "watch-3": { startToken: null, activities: [] },
    },
  });
  h.setSnapshot({ activeRuns: [runView()], lastFinished: null });
  h.notifier.noteChange();
  await h.notifier.settled();

  assert.equal(h.sends.length, 2, "the device with no activity is skipped");
  assert.deepEqual(
    h.sends.map((send) => [send.deviceToken, send.environment]),
    [
      [UPDATE_TOKEN, "sandbox"],
      [START_TOKEN, "production"],
    ],
  );
});
