import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  VERSION,
  buildChunkRecords,
  buildLexicon,
  hybridSearch,
  lexicalFilter,
  readVaultRecords,
} from "../electron/brainIndex.mjs";

function makeVault(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "iris-brain-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test("brain index v2 chunks long notes while lexical records remain note-level", (t) => {
  const root = makeVault(t);
  const longBody = Array.from(
    { length: 80 },
    (_, index) => `Paragraph ${index}: Project Aurora decision and supporting detail ${"x".repeat(55)}.`,
  ).join("\n\n");
  fs.writeFileSync(
    path.join(root, "Aurora.md"),
    `---\ntags: project decision\naliases: Northern Lights\n---\n# Aurora\n\n${longBody}`,
  );

  const records = readVaultRecords(root);
  const chunks = buildChunkRecords(records);
  assert.equal(VERSION, 2);
  assert.equal(records.length, 1);
  assert.ok(chunks.length > 2);
  assert.equal(new Set(chunks.map((chunk) => chunk.id)).size, chunks.length);
  assert.ok(chunks.every((chunk) => chunk.embedText.includes("Title: Aurora")));

  const matches = lexicalFilter(buildLexicon(records), "aurora decision");
  assert.equal(matches.length, 1);
  assert.equal(matches[0].rel, "Aurora.md");
});

test("semantic-only hits return the matching chunk snippet", (t) => {
  const root = makeVault(t);
  fs.writeFileSync(path.join(root, "Alpha.md"), "# Alpha\n\nThe launch checklist is stored here.");
  const records = readVaultRecords(root);
  const lexicon = buildLexicon(records);
  const index = {
    manifest: {
      version: 2,
      dims: 2,
      notes: [
        {
          path: "Alpha.md",
          title: "Alpha",
          folder: "root",
          snippet: "Semantic chunk containing the launch checklist.",
          mtimeMs: Date.now(),
        },
      ],
    },
    vectors: new Float32Array([1, 0]),
  };
  const [hit] = hybridSearch({
    lexicon,
    index,
    queryVector: new Float32Array([1, 0]),
    query: "orbital readiness phrase",
    topK: 1,
  });
  assert.equal(hit.rel, "Alpha.md");
  assert.equal(hit.cosScore, 1);
  assert.match(hit.snippet, /Semantic chunk/);
});

// ---------- embedding under quota pressure (#8) ----------

import { parseRetryAfter, syncBrainIndex, loadIndexFromDisk, EMBED_DIMS } from "../electron/brainIndex.mjs";

/** Keeps ~/.iris/brain-index out of the real home for the duration of a test. */
function isolateHome(t) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "iris-home-"));
  const previous = process.env.HOME;
  process.env.HOME = home;
  t.after(() => {
    process.env.HOME = previous;
    fs.rmSync(home, { recursive: true, force: true });
  });
  return home;
}

/** Ten short notes: one chunk each, so `batchSize: 4` means three batches. */
function seedNotes(root, count = 10) {
  for (let i = 0; i < count; i += 1) {
    fs.writeFileSync(path.join(root, `Note-${i}.md`), `# Note ${i}\n\nBody of note number ${i}.`);
  }
}

/**
 * A fake Gemini that answers batchEmbedContents with unit vectors and follows
 * a script of per-call outcomes: "ok", or { status, retryAfter? }.
 */
function fakeEmbedApi(t, script, { scriptProbes = false } = {}) {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    // The model probe is not part of the run under test: it always succeeds
    // and is neither scripted nor counted.
    const isProbe = !scriptProbes && body.requests.length === 1 && body.requests[0].content.parts[0].text === "probe";
    const step = isProbe ? "ok" : script.length ? script.shift() : "ok";
    const model = String(url).match(/models\/([^:]+):/)?.[1];
    if (!isProbe) calls.push({ at: Date.now(), size: body.requests.length, step, model });
    if (step !== "ok") {
      return new Response(JSON.stringify({ error: { code: step.status, message: "quota" } }), {
        status: step.status,
        headers: step.retryAfter !== undefined ? { "retry-after": String(step.retryAfter) } : {},
      });
    }
    const embeddings = body.requests.map((_, i) => {
      const values = new Array(EMBED_DIMS).fill(0);
      values[i % EMBED_DIMS] = 1;
      return { values };
    });
    return new Response(JSON.stringify({ embeddings }), { status: 200 });
  };
  t.after(() => { globalThis.fetch = real; });
  return calls;
}

test("Retry-After is read as seconds or as an HTTP-date", () => {
  const now = Date.parse("2026-09-25T12:00:00Z");
  assert.equal(parseRetryAfter("7"), 7000);
  assert.equal(parseRetryAfter("Thu, 25 Sep 2026 12:00:30 GMT", now), 30000);
  assert.equal(parseRetryAfter("garbage"), null);
  assert.equal(parseRetryAfter(null), null);
});

test("a 429 with Retry-After is waited out once and the run completes", async (t) => {
  isolateHome(t);
  const root = makeVault(t);
  seedNotes(root);
  const calls = fakeEmbedApi(t, [{ status: 429, retryAfter: 1 }, "ok", "ok", "ok"]);

  const result = await syncBrainIndex({ vaultRoot: root, apiKey: "k", batchSize: 4, log: () => {} });

  assert.equal(result.ok, true);
  assert.equal(result.embedded, 10);
  assert.equal(calls.length, 4, "one refused call, then three batches");
  const waited = calls[1].at - calls[0].at;
  assert.ok(waited >= 1000 && waited < 2000, `waited ${waited}ms — Retry-After: 1 plus jitter, not the 800ms schedule`);
  // After the quota hit the batches shrink for the rest of the run.
  assert.deepEqual(calls.slice(1).map((c) => c.size), [4, 4, 2], "a 4-chunk floor is the test's own batch size");
  const onDisk = loadIndexFromDisk(root);
  assert.equal(onDisk.manifest.notes.length, 10);
  assert.equal(onDisk.manifest.partial, undefined);
});

test("a run cut short by quota leaves a checkpoint, and the rerun embeds only the rest", async (t) => {
  isolateHome(t);
  const root = makeVault(t);
  seedNotes(root);
  // Batch 1 succeeds; batch 2 is refused past every quota retry.
  const refusals = Array.from({ length: 5 }, () => ({ status: 429, retryAfter: 0 }));
  const calls = fakeEmbedApi(t, ["ok", ...refusals]);
  const logs = [];

  await assert.rejects(
    syncBrainIndex({ vaultRoot: root, apiKey: "k", batchSize: 4, log: (m) => logs.push(m) }),
    /Embedding HTTP 429/,
  );
  const checkpoint = loadIndexFromDisk(root);
  assert.ok(checkpoint, "a checkpoint must exist after the failure");
  assert.equal(checkpoint.manifest.partial, true);
  assert.equal(checkpoint.manifest.notes.length, 4, "exactly the first batch");
  assert.ok(logs.some((m) => /checkpoint written: 4 of 10/.test(m)));

  const before = calls.length;
  const second = await syncBrainIndex({ vaultRoot: root, apiKey: "k", batchSize: 4, log: (m) => logs.push(m) });
  assert.equal(second.reused, 4);
  assert.equal(second.embedded, 6);
  assert.ok(logs.some((m) => /resuming: 4 of 10 chunks already embedded/.test(m)));
  assert.equal(calls.slice(before).reduce((n, c) => n + c.size, 0), 6, "only the missing chunks were sent");

  const final = loadIndexFromDisk(root);
  assert.equal(final.manifest.notes.length, 10);
  assert.equal(final.manifest.partial, undefined);
  assert.equal(final.vectors.length, 10 * EMBED_DIMS);
});

test("a query embed on quota waits Retry-After once, then gives up fast", async (t) => {
  isolateHome(t);
  const calls = fakeEmbedApi(t, [{ status: 429, retryAfter: 1 }, { status: 429, retryAfter: 60 }]);
  const { embedQuery } = await import("../electron/brainIndex.mjs");
  const started = Date.now();
  await assert.rejects(embedQuery({ apiKey: "k", model: "m", text: "hello" }), /Embedding HTTP 429/);
  const took = Date.now() - started;
  assert.equal(calls.length, 2, "one wait, one more try, then fail over to lexical");
  assert.ok(took >= 1000 && took < 4000, `took ${took}ms — never the indexer's two-minute schedule`);
});

test("a quota hit on the probe does not switch embedding models", async (t) => {
  isolateHome(t);
  const root = makeVault(t);
  seedNotes(root, 2);
  // Both probe attempts are refused; the fake answers probes from the script
  // when told to, so this run's probe sees the 429s.
  const calls = fakeEmbedApi(t, Array.from({ length: 6 }, () => ({ status: 429, retryAfter: 0 })), { scriptProbes: true });
  await assert.rejects(
    syncBrainIndex({ vaultRoot: root, apiKey: "k", batchSize: 4, log: () => {} }),
    /Embedding HTTP 429/,
  );
  const models = new Set(calls.map((c) => c.model));
  assert.deepEqual([...models], ["gemini-embedding-2-preview"], "never fell through to the older model on a 429");
  assert.equal(loadIndexFromDisk(root), null, "nothing earned, nothing written");
});

