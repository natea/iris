import test from "node:test";
import assert from "node:assert/strict";
import {
  MAX_PREVIEW_CHARS,
  REDACTED,
  createRunSteps,
  parseStepsSince,
  redactSecrets,
  sanitizePreview,
  stepDetail,
  stepHeadline,
  stripControlCharacters,
  toolCategory,
} from "../electron/runSteps.mjs";

// The renderer's own implementation. Node strips the types on import, so the
// parity test below compares the port against the real source of truth rather
// than a copy of it.
import * as rendererTasks from "../src/lib/tasks.ts";

function started({ runId = "run-1", tool, preview = "", toolId, ts }) {
  return {
    type: "hermes_task_event",
    run_id: runId,
    event: "tool.started",
    tool,
    tool_id: toolId,
    preview,
    ts,
  };
}

function completed({ runId = "run-1", tool, toolId, duration = 1.2, isError = false, ts }) {
  return {
    type: "hermes_task_event",
    run_id: runId,
    event: "tool.completed",
    tool,
    tool_id: toolId,
    duration,
    is_error: isError,
    ts,
  };
}

test("a tool start is paired with its completion and keeps order", () => {
  const steps = createRunSteps();
  steps.record(started({ tool: "Terminal", preview: "osascript -e 'tell application'", ts: 1000 }));
  steps.record(started({ tool: "web_search", preview: "https://www.example.com/a?b=1", ts: 1001 }));
  steps.record(completed({ tool: "web_search", duration: 0.5, ts: 1002 }));

  const snap = steps.snapshot("run-1");
  assert.equal(snap.step_count, 2);
  assert.deepEqual(
    snap.steps.map((step) => [step.tool, step.status, step.duration_ms]),
    [
      ["Terminal", "running", null],
      ["web_search", "done", 500],
    ],
  );
  assert.equal(snap.steps[0].category, "code");
  assert.equal(snap.steps[1].category, "search");
  assert.equal(snap.steps[1].label, "example.com");
  assert.equal(snap.steps[0].started_at, 1000 * 1000);
  assert.equal(snap.steps_complete, true);
});

test("a completion pairs with the newest running step of the same tool", () => {
  const steps = createRunSteps();
  steps.record(started({ tool: "Terminal", preview: "first" }));
  steps.record(started({ tool: "Terminal", preview: "second" }));
  steps.record(completed({ tool: "Terminal", duration: 2 }));

  const snap = steps.snapshot("run-1");
  assert.deepEqual(
    snap.steps.map((step) => [step.preview, step.status]),
    [
      ["first", "running"],
      ["second", "done"],
    ],
  );
});

test("an explicit tool id pairs across interleaved tools", () => {
  const steps = createRunSteps();
  steps.record(started({ tool: "Terminal", toolId: "a", preview: "one" }));
  steps.record(started({ tool: "Terminal", toolId: "b", preview: "two" }));
  steps.record(completed({ tool: "Terminal", toolId: "a", duration: 3 }));

  const snap = steps.snapshot("run-1");
  assert.deepEqual(
    snap.steps.map((step) => [step.preview, step.status, step.duration_ms]),
    [
      ["one", "done", 3000],
      ["two", "running", null],
    ],
  );
});

test("an errored completion is reported as failed", () => {
  const steps = createRunSteps();
  steps.record(started({ tool: "Terminal", preview: "boom" }));
  steps.record(completed({ tool: "Terminal", isError: true, duration: 0.25 }));
  assert.equal(steps.snapshot("run-1").steps[0].status, "failed");
  assert.equal(steps.snapshot("run-1").steps[0].duration_ms, 250);
});

test("headlines follow the desktop card's wording and transitions", () => {
  const steps = createRunSteps();
  assert.equal(steps.snapshot("run-1").headline, "");

  steps.record(started({ tool: "Terminal", preview: "ls" }));
  assert.equal(steps.summary("run-1").headline, "Running code");

  steps.record(completed({ tool: "Terminal" }));
  // Nothing running, but real steps exist: the card says "Thinking…".
  assert.equal(steps.summary("run-1").headline, "Thinking…");

  steps.record(started({ tool: "web_search", preview: "https://duckduckgo.com/?q=x" }));
  assert.equal(steps.summary("run-1").headline, "Searching duckduckgo.com");

  steps.record(completed({ tool: "web_search" }));
  steps.record(started({ tool: "browser_navigate", preview: "not-a-url" }));
  assert.equal(steps.summary("run-1").headline, "Browsing not-a-url");

  steps.record(started({ tool: "read_file", preview: "/tmp/notes/plan.md" }));
  assert.equal(steps.summary("run-1").headline, "Working on plan.md");

  steps.record(started({ tool: "weather_lookup", preview: "" }));
  assert.equal(steps.summary("run-1").headline, "Using weather lookup");
});

test("a run with no events reports nothing and says the list is not complete", () => {
  const steps = createRunSteps();
  assert.deepEqual(steps.snapshot("never-seen"), {
    headline: "",
    step_count: 0,
    steps: [],
    steps_cursor: 0,
    steps_complete: false,
    steps_truncated: false,
  });
  assert.deepEqual(steps.summary("never-seen"), { headline: "", step_count: 0 });
});

test("unknown, malformed and orphaned events are ignored without throwing", () => {
  const steps = createRunSteps();
  steps.record(undefined);
  steps.record(null);
  steps.record("nope");
  steps.record({});
  steps.record({ type: "hermes_task_event" });
  steps.record({ type: "log", run_id: "run-1", message: "hi" });
  steps.record({ type: "hermes_task_event", run_id: "run-1", event: "message.delta", delta: "x" });
  steps.record({ type: "hermes_task_event", run_id: "run-1", event: "tool.started" });
  // A completion for a run that was never started is not a step we can
  // honestly describe.
  steps.record(completed({ tool: "Terminal" }));
  assert.deepEqual(steps.snapshot("run-1").steps, []);
  assert.equal(steps.size(), 0);
});

test("the step list is bounded and says so when it drops older steps", () => {
  const steps = createRunSteps({ maxStepsPerRun: 5 });
  for (let i = 0; i < 12; i++) {
    steps.record(started({ tool: "Terminal", preview: `cmd-${i}` }));
    steps.record(completed({ tool: "Terminal" }));
  }
  const snap = steps.snapshot("run-1");
  assert.equal(snap.step_count, 5);
  assert.equal(snap.steps_truncated, true);
  assert.equal(snap.steps_complete, false);
  assert.deepEqual(
    snap.steps.map((step) => step.preview),
    ["cmd-7", "cmd-8", "cmd-9", "cmd-10", "cmd-11"],
  );
});

test("finished runs are evicted and the run map never grows without bound", () => {
  let clock = 1_000_000;
  const steps = createRunSteps({ finishedTtlMs: 60_000, now: () => clock });
  steps.record(started({ runId: "old", tool: "Terminal", preview: "x", ts: clock / 1000 }));
  steps.record({ type: "hermes_task_update", run_id: "old", status: "completed" });
  assert.equal(steps.size(), 1);

  clock += 120_000;
  steps.record(started({ runId: "new", tool: "Terminal", preview: "y", ts: clock / 1000 }));
  assert.equal(steps.size(), 1);
  assert.equal(steps.snapshot("old").steps_complete, false);
  assert.equal(steps.snapshot("new").step_count, 1);
});

test("the least recently active run is evicted past the run cap", () => {
  let clock = 1_000;
  const steps = createRunSteps({ maxRuns: 2, now: () => clock });
  for (const runId of ["a", "b", "c"]) {
    clock += 1_000;
    steps.record(started({ runId, tool: "Terminal", preview: runId, ts: clock / 1000 }));
  }
  assert.equal(steps.size(), 2);
  assert.equal(steps.snapshot("a").step_count, 0);
  assert.equal(steps.snapshot("c").step_count, 1);
});

test("an idle run with no terminal event still ages out", () => {
  let clock = 1_000_000;
  const steps = createRunSteps({ idleTtlMs: 10_000, now: () => clock });
  steps.record(started({ runId: "stale", tool: "Terminal", preview: "x", ts: clock / 1000 }));
  clock += 20_000;
  steps.record(started({ runId: "fresh", tool: "Terminal", preview: "y", ts: clock / 1000 }));
  assert.equal(steps.size(), 1);
  assert.equal(steps.snapshot("stale").step_count, 0);
});

test("steps_since returns only new or changed steps and the cursor advances", () => {
  const steps = createRunSteps();
  steps.record(started({ tool: "Terminal", preview: "one" }));
  const first = steps.snapshot("run-1");
  assert.equal(first.steps.length, 1);
  assert.equal(first.steps_cursor, 1);

  const unchanged = steps.snapshot("run-1", { since: first.steps_cursor });
  assert.deepEqual(unchanged.steps, []);
  assert.equal(unchanged.step_count, 1);

  // Completing the existing step changes it, so it comes back again.
  steps.record(completed({ tool: "Terminal", duration: 1 }));
  steps.record(started({ tool: "web_search", preview: "https://example.com" }));
  const delta = steps.snapshot("run-1", { since: first.steps_cursor });
  assert.deepEqual(
    delta.steps.map((step) => [step.id, step.status]),
    [
      ["s1", "done"],
      ["s3", "running"],
    ],
  );
  assert.equal(delta.steps_cursor, 3);

  // A step id is a valid cursor: both are drawn from one counter.
  assert.equal(parseStepsSince("s2"), 2);
  assert.equal(parseStepsSince("2"), 2);
  assert.equal(parseStepsSince("garbage"), null);
  assert.equal(parseStepsSince(""), null);
  assert.equal(steps.snapshot("run-1", { since: parseStepsSince("garbage") }).steps.length, 2);
});

test("previews are redacted, de-controlled and capped", () => {
  assert.equal(redactSecrets("export API_KEY=abc123supersecret"), `export ${REDACTED}`);
  assert.equal(redactSecrets('curl -H "Authorization: Bearer abcdef1234567890"'), 'curl -H "[redacted]"');
  assert.match(redactSecrets("token: sk-ABCDEFGHIJKLMNOPQRSTUV"), /^\[redacted\]$/);
  assert.match(redactSecrets("use ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"), /\[redacted\]/);
  assert.match(redactSecrets("aws AKIAABCDEFGHIJKLMNOP now"), /aws \[redacted\] now/);
  assert.match(redactSecrets("PASSWORD='hunter2'"), /^\[redacted\]$/);
  // A 40-character git SHA and ordinary paths stay readable.
  const sha = "a".repeat(40);
  assert.equal(redactSecrets(`git show ${sha}`), `git show ${sha}`);
  assert.equal(
    redactSecrets("/Users/nate/Documents/code/iris/electron/runSteps.mjs"),
    "/Users/nate/Documents/code/iris/electron/runSteps.mjs",
  );
  // A bare high-entropy blob is not.
  assert.match(redactSecrets(`echo ${"A1b2".repeat(12)}`), /\[redacted\]/);

  assert.equal(stripControlCharacters("a\u001b[31mred\u001b[0m\nb\tc\u0000"), "a red b c");
  const long = sanitizePreview("echo hello ".repeat(MAX_PREVIEW_CHARS));
  assert.equal(long.length, MAX_PREVIEW_CHARS + 1);
  assert.ok(long.endsWith("…"));
});

test("a recorded step never stores the raw secret", () => {
  const steps = createRunSteps();
  steps.record(
    started({
      tool: "Terminal",
      preview: 'curl -H "Authorization: Bearer sk-live-0123456789abcdef" https://api.example.com',
    }),
  );
  const step = steps.snapshot("run-1").steps[0];
  assert.equal(step.preview.includes("sk-live-0123456789abcdef"), false);
  assert.match(step.preview, /\[redacted\]/);
  assert.equal(step.label.includes("sk-live"), false);
});

// ===== Parity with the renderer =====

const PARITY_FIXTURE = [
  { tool: "Terminal", preview: "osascript <<'EOF' tell application \"Finder\"" },
  { tool: "run_shell_command", preview: "ls -la /tmp" },
  { tool: "web_search", preview: "https://www.example.com/search?q=hermes" },
  { tool: "web_search", preview: "plain query text" },
  { tool: "browser_navigate", preview: "https://news.ycombinator.com/item?id=1" },
  { tool: "browser_navigate", preview: "" },
  { tool: "fetch_url", preview: "not a url at all" },
  { tool: "read_file", preview: "/Users/nate/projects/iris/README.md" },
  { tool: "write_file", preview: "notes\\deep\\plan.txt" },
  { tool: "apply_patch", preview: "" },
  { tool: "weather.lookup", preview: "" },
  { tool: "some_other_tool", preview: "a ".repeat(80) },
  { tool: "python_exec", preview: "print('hi')\n\nprint('bye')" },
  { tool: "", preview: "orphan" },
];

test("the ported step logic matches src/lib/tasks.ts for the shared fixture", () => {
  for (const item of PARITY_FIXTURE) {
    const step = { id: "x", tool: item.tool, preview: item.preview, status: "running", ts: 0 };
    assert.equal(
      toolCategory(item.tool),
      rendererTasks.toolCategory(item.tool),
      `category for ${item.tool}`,
    );
    assert.equal(stepDetail(step), rendererTasks.stepDetail(step), `detail for ${item.tool}`);
    assert.equal(
      stepHeadline(step),
      rendererTasks.stepHeadline(step),
      `headline for ${item.tool}`,
    );
  }
});

test("the accumulator's headline matches what the desktop card would render", () => {
  const steps = createRunSteps();
  for (const item of PARITY_FIXTURE) {
    if (!item.tool) continue;
    steps.record(started({ tool: item.tool, preview: item.preview }));
    const rendered = steps.snapshot("run-1").steps;
    const running = [...rendered].reverse().find((step) => step.status === "running");
    // WorkCard.tsx: the newest running step drives the "activity now" line.
    assert.equal(
      steps.summary("run-1").headline,
      rendererTasks.stepHeadline({
        id: running.id,
        tool: running.tool,
        preview: running.preview,
        status: "running",
        ts: 0,
      }),
    );
  }
});
