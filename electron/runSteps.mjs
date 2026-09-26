// Live progress for a Hermes run, kept in the main process.
//
// The desktop task card assembles "what Hermes is doing right now" in the
// RENDERER (src/lib/tasks.ts + src/components/WorkCard.tsx) out of the
// forwarded `hermes_task_event` stream. The main process, where Iris Link
// lives, only ever forwarded those events and kept nothing, so the phone had
// no way to see progress. This module is that missing memory: a pure,
// Electron-free accumulator fed the SAME normalized events the renderer gets.
//
// The categorization / label / headline rules below are a PORT of the pure
// logic in src/lib/tasks.ts. They are not imported (the main process must not
// load TypeScript); test/runSteps.test.mjs pins the two implementations to the
// same outputs for a shared fixture so they cannot silently drift.

// Keep the newest steps only. A long run can emit thousands of tool calls and
// the phone shows a short list; unbounded growth in a process that lives for
// days is not an option.
export const MAX_STEPS_PER_RUN = 60;
// Runs tracked at once, evicted least-recently-active first.
export const MAX_RUNS = 50;
// How long a finished run's steps stay answerable before eviction.
export const FINISHED_TTL_MS = 10 * 60 * 1000;
// A run that goes completely silent this long is assumed gone (the process
// missed its terminal event) and is evicted with the finished ones.
export const IDLE_TTL_MS = 6 * 60 * 60 * 1000;
export const MAX_PREVIEW_CHARS = 200;
export const MAX_LABEL_CHARS = 64;

export const TERMINAL_STATUSES = new Set([
  "completed",
  "failed",
  "cancelled",
  "canceled",
  "error",
]);

// ===== Ported from src/lib/tasks.ts (keep in sync; parity-tested) =====

/** @returns {"browser"|"search"|"code"|"file"|"tool"} */
export function toolCategory(tool) {
  const t = String(tool || "").toLowerCase();
  if (t.includes("search")) return "search";
  if (
    t.includes("browser") ||
    t.includes("navigate") ||
    t.includes("fetch") ||
    t.includes("web") ||
    t.includes("url")
  )
    return "browser";
  if (
    t.includes("code") ||
    t.includes("python") ||
    t.includes("shell") ||
    t.includes("bash") ||
    t.includes("exec") ||
    t.includes("terminal") ||
    t.includes("command") ||
    t.includes("run")
  )
    return "code";
  if (
    t.includes("file") ||
    t.includes("read") ||
    t.includes("write") ||
    t.includes("edit") ||
    t.includes("patch")
  )
    return "file";
  return "tool";
}

export function prettyToolName(tool) {
  return String(tool || "").replace(/[_.]+/g, " ").trim();
}

function hostFromUrl(value) {
  if (!value) return "";
  try {
    return new URL(value).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

function baseName(value) {
  if (!value) return "";
  const cleaned = value.split(/[?#]/)[0].replace(/[\\/]+$/, "");
  const parts = cleaned.split(/[\\/]/).filter(Boolean);
  return parts[parts.length - 1] ?? "";
}

/**
 * The short secondary detail the desktop shows beside a tool name: a host for
 * URLs, a filename for file tools, a trimmed single-line snippet otherwise.
 */
export function stepDetail(step) {
  const preview = step?.preview;
  if (!preview) return "";
  const category = toolCategory(step.tool);
  if (category === "browser" || category === "search") {
    return hostFromUrl(preview) || preview.slice(0, 60);
  }
  if (category === "file") {
    return baseName(preview) || preview.slice(0, 48);
  }
  const oneLine = preview.replace(/\s+/g, " ").trim();
  return oneLine.length > MAX_LABEL_CHARS
    ? `${oneLine.slice(0, MAX_LABEL_CHARS)}…`
    : oneLine;
}

/** One-line "what Hermes is doing right now" headline for an active step. */
export function stepHeadline(step) {
  const category = toolCategory(step?.tool);
  const detail = stepDetail(step);
  if (category === "browser") return detail ? `Browsing ${detail}` : "Browsing the web";
  if (category === "search") return detail ? `Searching ${detail}` : "Searching the web";
  if (category === "code") return "Running code";
  if (category === "file") return detail ? `Working on ${detail}` : "Working with files";
  return `Using ${prettyToolName(step?.tool)}`;
}

// ===== Redaction =====

export const REDACTED = "[redacted]";

// A terminal-command preview is the single most likely place for a credential
// to appear (an exported token, a curl header, a password flag). Anything that
// looks like one is replaced before it is stored, so it can never reach the
// phone, a log line, or a crash report.
const SECRET_PATTERNS = [
  // Authorization headers and bearer tokens.
  /\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi,
  /\bauthorization\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s"';|&]+)/gi,
  // key=value / key: "value" for anything that names itself a credential.
  /\b(?:[a-z0-9_.-]*(?:api[_-]?key|access[_-]?key|secret[_-]?key|auth[_-]?token|api[_-]?token|access[_-]?token|secret|password|passwd|pwd|token|credential|private[_-]?key|session[_-]?key))\b\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s"';|&]+)/gi,
  // Well-known token shapes, which carry no key name at all.
  /\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}/g,
  /\bgh[pousr]_[A-Za-z0-9]{16,}/g,
  /\bgithub_pat_[A-Za-z0-9_]{20,}/g,
  /\bxox[abprs]-[A-Za-z0-9-]{8,}/g,
  /\bAKIA[0-9A-Z]{16}\b/g,
  /\bAIza[0-9A-Za-z_-]{20,}/g,
  /\bey[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g,
  // A bare high-entropy blob with no key name at all. The 44-character floor
  // is deliberate: base64 of 32 random bytes is 44, while a 40-character git
  // SHA and ordinary long path segments stay readable.
  /\b[A-Za-z0-9+_]{44,}={0,2}\b/g,
];

export function redactSecrets(value) {
  let text = String(value || "");
  for (const pattern of SECRET_PATTERNS) {
    pattern.lastIndex = 0;
    text = text.replace(pattern, REDACTED);
  }
  return text;
}

// Control characters (ANSI escapes, carriage returns, NULs) would corrupt a
// JSON consumer's rendering; tabs and newlines become plain spaces.
export function stripControlCharacters(value) {
  return String(value || "")
    // ANSI escape sequences first, then every remaining C0/C1 control
    // character (tabs, newlines, carriage returns and NULs become spaces).
    .replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, " ")
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}

/** Redact, de-control, and cap a raw tool preview before it is ever stored. */
export function sanitizePreview(value) {
  const cleaned = stripControlCharacters(redactSecrets(value));
  if (!cleaned) return "";
  return cleaned.length > MAX_PREVIEW_CHARS
    ? `${cleaned.slice(0, MAX_PREVIEW_CHARS)}…`
    : cleaned;
}

// ===== The accumulator =====

function eventMillis(event, fallback) {
  const ts = event?.ts;
  if (typeof ts === "number" && Number.isFinite(ts)) {
    // The forwarded events carry seconds (Hermes' own unit), like the renderer.
    return ts > 1e12 ? ts : Math.round(ts * 1000);
  }
  return fallback;
}

/**
 * `steps_since` accepts either the integer cursor from a previous response or
 * a step id (`"s12"`). Both are drawn from one per-run counter, so a step id
 * is a valid cursor position. Anything else means "give me everything".
 */
/**
 * Steps for a FINISHED run, rebuilt from Hermes' saved transcript. Live steps
 * live in memory only — gone after a restart or ten minutes after the run ends
 * — but the transcript keeps every tool call, so a finished run need never say
 * "no step history". The transcript has no durations, and we do not invent
 * them: `duration_ms` stays null and the status is simply "done".
 */
export function snapshotFromHistory(historySteps, { limit = 60 } = {}) {
  const all = Array.isArray(historySteps) ? historySteps.filter((step) => step && step.tool) : [];
  const kept = all.slice(-limit);
  const steps = kept.map((step, position) => {
    const tool = String(step.tool);
    const preview = sanitizePreview(step.preview || "");
    const index = position + 1;
    return {
      id: `s${index}`,
      index,
      tool,
      category: toolCategory(tool),
      label: stepDetail({ tool, preview }),
      preview,
      status: "done",
      started_at: Number(step.ts) > 0 ? Number(step.ts) : 0,
      duration_ms: null,
    };
  });
  return {
    headline: "",
    step_count: steps.length,
    steps,
    steps_cursor: steps.length,
    steps_complete: all.length <= limit,
    steps_truncated: all.length > limit,
    steps_source: "transcript",
  };
}

export function parseStepsSince(raw) {
  if (raw === undefined || raw === null || raw === "") return null;
  const text = String(raw).trim();
  const match = /^s?(\d+)$/.exec(text);
  if (!match) return null;
  const value = Number(match[1]);
  return Number.isFinite(value) ? value : null;
}

export function createRunSteps({
  maxStepsPerRun = MAX_STEPS_PER_RUN,
  maxRuns = MAX_RUNS,
  finishedTtlMs = FINISHED_TTL_MS,
  idleTtlMs = IDLE_TTL_MS,
  now = () => Date.now(),
} = {}) {
  /** @type {Map<string, {seq:number, steps:any[], truncated:boolean, finishedAt:number, updatedAt:number}>} */
  const runs = new Map();

  function prune() {
    const at = now();
    for (const [runId, run] of runs) {
      if (run.finishedAt && at - run.finishedAt > finishedTtlMs) runs.delete(runId);
      else if (at - run.updatedAt > idleTtlMs) runs.delete(runId);
    }
    if (runs.size > maxRuns) {
      const ordered = [...runs.entries()].sort((a, b) => a[1].updatedAt - b[1].updatedAt);
      for (const [runId] of ordered.slice(0, runs.size - maxRuns)) runs.delete(runId);
    }
  }

  // Bookkeeping always uses the local clock. A step's `started_at` comes from
  // the event, which carries Hermes' timestamp and must never be allowed to
  // drive eviction.
  function ensure(runId) {
    let run = runs.get(runId);
    if (!run) {
      run = { seq: 0, steps: [], truncated: false, finishedAt: 0, updatedAt: now() };
      runs.set(runId, run);
    }
    run.updatedAt = now();
    return run;
  }

  function startStep(run, { tool, toolId, preview, at }) {
    run.seq += 1;
    const step = {
      id: `s${run.seq}`,
      seq: run.seq,
      updatedSeq: run.seq,
      toolId: toolId || "",
      tool,
      category: toolCategory(tool),
      preview: sanitizePreview(preview),
      status: "running",
      startedAt: at,
      durationMs: null,
    };
    run.steps.push(step);
    if (run.steps.length > maxStepsPerRun) {
      run.steps.splice(0, run.steps.length - maxStepsPerRun);
      run.truncated = true;
    }
    return step;
  }

  function completeStep(run, { tool, toolId, preview, duration, isError }) {
    // Prefer the transport's own tool id when it gives one; otherwise fall
    // back to the renderer's rule (the newest still-running step of the same
    // tool name).
    let target = null;
    for (let i = run.steps.length - 1; i >= 0; i--) {
      const step = run.steps[i];
      if (step.status !== "running") continue;
      if (toolId && step.toolId) {
        if (step.toolId === toolId) {
          target = step;
          break;
        }
        continue;
      }
      if (step.tool === tool) {
        target = step;
        break;
      }
    }
    if (!target) return null;
    run.seq += 1;
    target.updatedSeq = run.seq;
    target.status = isError ? "failed" : "done";
    if (typeof duration === "number" && Number.isFinite(duration)) {
      target.durationMs = Math.max(0, Math.round(duration * 1000));
    }
    // A completion can carry a better summary than the start did.
    const better = sanitizePreview(preview);
    if (better && !target.preview) target.preview = better;
    return target;
  }

  function publicStep(step) {
    return {
      id: step.id,
      index: step.seq,
      tool: step.tool,
      category: step.category,
      label: stepDetail({ tool: step.tool, preview: step.preview }),
      preview: step.preview,
      status: step.status,
      started_at: step.startedAt,
      duration_ms: step.durationMs,
    };
  }

  function headlineFor(run) {
    if (!run || !run.steps.length) return "";
    for (let i = run.steps.length - 1; i >= 0; i--) {
      if (run.steps[i].status === "running") {
        return stepHeadline({ tool: run.steps[i].tool, preview: run.steps[i].preview });
      }
    }
    return "Thinking…";
  }

  return {
    /**
     * Feed one emitted desktop event. Unknown types, malformed payloads and
     * events without a run id are ignored — this must never throw into the
     * event path it is hooked onto.
     */
    record(event) {
      if (!event || typeof event !== "object") return;
      const runId = String(event.run_id || "");
      if (!runId) return;
      const at = eventMillis(event, now());
      const type = String(event.type || "");

      if (type === "hermes_task_update" || type === "hermes_completion") {
        const status = String(event.status || "").toLowerCase();
        if (!TERMINAL_STATUSES.has(status)) return;
        const run = runs.get(runId);
        if (run) {
          run.finishedAt = now();
          run.updatedAt = now();
        }
        prune();
        return;
      }

      if (type !== "hermes_task_event") return;
      const kind = String(event.event || "");
      const tool = typeof event.tool === "string" ? event.tool : "";
      if (kind === "tool.started") {
        if (!tool) return;
        const run = ensure(runId);
        run.finishedAt = 0;
        startStep(run, {
          tool,
          toolId: typeof event.tool_id === "string" ? event.tool_id : "",
          preview: typeof event.preview === "string" ? event.preview : "",
          at,
        });
        prune();
        return;
      }
      if (kind === "tool.completed") {
        if (!tool) return;
        const run = runs.get(runId);
        // A completion with no recorded start is not a step we can honestly
        // describe, so it is dropped rather than invented.
        if (!run) return;
        run.updatedAt = now();
        completeStep(run, {
          tool,
          toolId: typeof event.tool_id === "string" ? event.tool_id : "",
          preview: typeof event.preview === "string" ? event.preview : "",
          duration: event.duration,
          isError: event.is_error === true,
        });
        prune();
      }
    },

    /** Mark a run terminal so its steps age out of memory. */
    finish(runId) {
      const run = runs.get(String(runId || ""));
      if (!run) return;
      run.finishedAt = now();
      run.updatedAt = now();
      prune();
    },

    forget(runId) {
      runs.delete(String(runId || ""));
    },

    /**
     * What a Live Activity needs and nothing more: the headline, the count,
     * whether the history can be vouched for, and the running step's own
     * preview. Allocates no step objects, because this is called on the event
     * path rather than on a request.
     */
    progress(runId) {
      const run = runs.get(String(runId || ""));
      if (!run) return { headline: "", step_count: 0, steps_complete: false, detail: "" };
      let detail = "";
      for (let i = run.steps.length - 1; i >= 0; i--) {
        if (run.steps[i].status === "running") {
          detail = run.steps[i].preview;
          break;
        }
      }
      return {
        headline: headlineFor(run),
        step_count: run.steps.length,
        steps_complete: !run.truncated,
        detail,
      };
    },

    /** `{headline, step_count}` for a list entry — never the full step list. */
    summary(runId) {
      const run = runs.get(String(runId || ""));
      return {
        headline: headlineFor(run),
        step_count: run ? run.steps.length : 0,
      };
    },

    /**
     * Full live-progress block for a run detail view. `since` is the cursor or
     * step id from the previous response; only steps created or changed after
     * it come back. `steps_complete` is false whenever Iris cannot vouch for
     * the list being the whole story (nothing recorded, an Iris restart, or
     * older steps evicted by the bound).
     */
    snapshot(runId, { since = null } = {}) {
      const run = runs.get(String(runId || ""));
      if (!run) {
        return {
          headline: "",
          step_count: 0,
          steps: [],
          steps_cursor: 0,
          steps_complete: false,
          steps_truncated: false,
        };
      }
      const cursor = typeof since === "number" && Number.isFinite(since) ? since : null;
      const steps = (cursor === null
        ? run.steps
        : run.steps.filter((step) => step.updatedSeq > cursor)
      ).map(publicStep);
      return {
        headline: headlineFor(run),
        step_count: run.steps.length,
        steps,
        steps_cursor: run.seq,
        steps_complete: !run.truncated,
        steps_truncated: run.truncated,
      };
    },

    /** Test/diagnostic surface only. */
    size() {
      return runs.size;
    },
  };
}
