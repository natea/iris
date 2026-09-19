// Throwaway E2E harness. Runs the REAL Iris Link server (electron/irisLinkServer.mjs
// + electron/pairingStore.mjs) on 127.0.0.1, mints REAL ephemeral tokens with the
// real mobile config builder (electron/mobileSession.mjs), and wires FAKE task
// handlers so no actual Hermes work is dispatched.
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { GoogleGenAI } from "../../../node_modules/@google/genai/dist/node/index.mjs";
import { createIrisLinkServer } from "../../../electron/irisLinkServer.mjs";
import { createPairingStore } from "../../../electron/pairingStore.mjs";
import { buildMobileLiveConfig } from "../../../electron/mobileSession.mjs";

const SCRATCH = process.env.SCRATCH || fs.mkdtempSync(path.join(os.tmpdir(), "iris-link-harness-"));
const PORT = Number(process.env.PORT || 8799);
// The real Iris Link server listens here; the shim below fronts it on PORT.
const UPSTREAM_PORT = PORT + 1;
// After this many honored resumes, pretend the handle was rejected. Lets one
// probe run cover both the resumed path and the "could not be restored" path.
const REFUSE_RESUME_AFTER = Number(process.env.REFUSE_RESUME_AFTER || Infinity);
const USER = "Nate";
const MODEL = "models/gemini-3.1-flash-live-preview";
// How long a fake run "works" before it turns terminal.
const COMPLETE_AFTER_MS = Number(process.env.COMPLETE_AFTER_MS || 12_000);

// The key is read straight out of ~/.iris/.env and never printed.
const envText = fs.readFileSync(path.join(os.homedir(), ".iris", ".env"), "utf8");
const apiKey = (envText.match(/^GEMINI_API_KEY=(.*)$/m)?.[1] || "").trim();
if (!apiKey) throw new Error("no GEMINI_API_KEY in ~/.iris/.env");

const log = (...parts) => console.log("HARNESS", ...parts);

const runs = new Map();
let nextRun = 1;

function summary(entry) {
  return {
    run_id: entry.runId,
    task: entry.task,
    status: entry.status,
    origin: entry.origin,
    created_at: entry.createdAt,
    updated_at: entry.updatedAt,
    announced_at: entry.announcedAt,
  };
}

fs.mkdirSync(SCRATCH, { recursive: true });

const store = createPairingStore({ file: path.join(SCRATCH, "devices.json") });

const server = createIrisLinkServer({
  pairingStore: store,
  mintGeminiToken: async () => {
    const expiresAt = new Date(Date.now() + 30 * 60 * 1000).toISOString();
    const newSessionExpiresAt = new Date(Date.now() + 60 * 1000).toISOString();
    const ai = new GoogleGenAI({ apiKey, httpOptions: { apiVersion: "v1alpha" } });
    // The resume handle the phone asked for, picked up by the shim below.
    // A real desktop would read it from the request body in
    // irisLinkServer.mjs and pass it down here; this harness is standing in
    // for that one change so the phone's half can be proved end to end.
    const requested = pendingResumeHandle;
    pendingResumeHandle = "";
    const honor = Boolean(requested) && resumesHonored < REFUSE_RESUME_AFTER;
    if (requested && !honor) log("RESUME_REFUSED (standing in for a rejected/expired handle)");
    if (honor) resumesHonored += 1;
    const token = await ai.authTokens.create({
      config: {
        uses: 1,
        expireTime: expiresAt,
        newSessionExpireTime: newSessionExpiresAt,
        liveConnectConstraints: {
          model: MODEL,
          config: buildMobileLiveConfig({
            userName: USER,
            voice: "Zephyr",
            resumeHandle: honor ? requested : "",
          }),
        },
      },
    });
    lastMintResumed = honor;
    log("MINTED_TOKEN", honor ? "RESUMING" : "FRESH");
    return { token: token.name, expiresAt, newSessionExpiresAt, model: MODEL };
  },
  checkHermesReachable: async () => true,
  getInfo: () => ({
    hermesReachable: true,
    userName: USER,
    liveModel: MODEL,
    voice: "Zephyr",
    accent: "",
  }),
  tasks: {
    // THE fake dispatch. Nothing leaves this process.
    dispatch: async ({ task, urgency, deviceId }) => {
      const runId = `fake-run-${nextRun++}`;
      const at = Date.now();
      const entry = {
        runId,
        task,
        urgency,
        status: "running",
        origin: `device:${deviceId}`,
        createdAt: at,
        updatedAt: at,
        announcedAt: 0,
        output: "",
      };
      runs.set(runId, entry);
      log("DISPATCH_RECEIVED", JSON.stringify({ run_id: runId, urgency, task }));
      setTimeout(() => {
        entry.status = "completed";
        entry.updatedAt = Date.now();
        entry.output =
          "Counted 42 files in ~/Downloads. The largest is report.pdf at 12 MB.";
        log("RUN_TERMINAL", runId, entry.status);
      }, COMPLETE_AFTER_MS);
      return { status: "started", run_id: runId, message: "Hermes has started the task.", origin: entry.origin };
    },
    list: ({ deviceId, undelivered }) => {
      const mine = `device:${deviceId}`;
      return [...runs.values()]
        .filter((entry) =>
          !undelivered
            ? true
            : ["completed", "failed", "cancelled", "canceled", "error"].includes(entry.status) &&
              entry.origin === mine &&
              !entry.announcedAt,
        )
        .sort((a, b) => b.updatedAt - a.updatedAt)
        .map(summary);
    },
    get: async ({ runId }) => {
      const entry = runs.get(runId);
      if (!entry) return { error: "task_unknown" };
      log("STATUS_ASKED", runId, entry.status);
      const terminal = ["completed", "failed", "cancelled", "canceled", "error"].includes(entry.status);
      return {
        ...summary(entry),
        status: entry.status,
        ...(terminal ? { output: entry.output } : {}),
        instructions: terminal
          ? "The run is finished."
          : "The run is STILL IN PROGRESS. There is NO result yet.",
      };
    },
    result: async ({ runId }) => {
      const entry = runs.get(runId);
      if (!entry) return { ok: false, error: "task_unknown" };
      if (!["completed", "failed", "cancelled", "canceled", "error"].includes(entry.status)) {
        return { ok: false, error: "task_not_finished" };
      }
      log("RESULT_READ", runId);
      return {
        ok: true,
        run_id: runId,
        task: entry.task,
        status: entry.status,
        output: entry.output,
        instructions: "Answer only from this complete Hermes result.",
      };
    },
    stop: async ({ runId }) => {
      const entry = runs.get(runId);
      if (!entry) return { ok: false, error: "task_unknown" };
      entry.status = "cancelled";
      entry.updatedAt = Date.now();
      log("STOP", runId);
      return { status: "stopping" };
    },
    approve: async ({ runId, decision }) => {
      log("APPROVAL", runId, decision);
      if (!runs.has(runId)) return { ok: false, error: "task_unknown" };
      return { ok: true };
    },
    markAnnounced: ({ runId }) => {
      const entry = runs.get(runId);
      if (!entry) return { ok: false, error: "task_unknown" };
      entry.announcedAt = Date.now();
      log("ANNOUNCED_ACK", runId);
      return { ok: true };
    },
  },
  log: (entry) => log("LOG", entry.level, entry.message),
});

// ===== The one desktop change this harness stands in for =====
//
// POST /link/gemini-token has to accept an optional {"resume_handle"} and
// answer with {"resumed": true|false}, because a handle only works when it is
// baked into the token's own liveConnectConstraints.config — a phone cannot
// present one on the constrained endpoint (measured; see mobileSession.mjs).
// That route lives in electron/irisLinkServer.mjs, which this task may not
// edit, so the real server runs behind this shim instead.
let pendingResumeHandle = "";
let lastMintResumed = false;
let resumesHonored = 0;

await server.listen({ host: "127.0.0.1", port: UPSTREAM_PORT });

const shim = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    const body = Buffer.concat(chunks);
    const isTokenRoute = req.method === "POST" && req.url === "/link/gemini-token";
    if (isTokenRoute) {
      try {
        const parsed = JSON.parse(body.toString("utf8") || "{}");
        pendingResumeHandle = String(parsed.resume_handle || "").trim();
        if (pendingResumeHandle) log("RESUME_HANDLE_REQUESTED (len", pendingResumeHandle.length, ")");
      } catch {
        pendingResumeHandle = "";
      }
    }
    const upstream = http.request(
      { host: "127.0.0.1", port: UPSTREAM_PORT, method: req.method, path: req.url, headers: req.headers },
      (upstreamRes) => {
        const out = [];
        upstreamRes.on("data", (chunk) => out.push(chunk));
        upstreamRes.on("end", () => {
          let payload = Buffer.concat(out);
          if (isTokenRoute && upstreamRes.statusCode === 200) {
            try {
              const json = JSON.parse(payload.toString("utf8"));
              json.resumed = lastMintResumed;
              payload = Buffer.from(JSON.stringify(json));
            } catch { /* pass it through untouched */ }
          }
          const headers = { ...upstreamRes.headers };
          delete headers["content-length"];
          res.writeHead(upstreamRes.statusCode, headers);
          res.end(payload);
        });
      },
    );
    upstream.on("error", () => { res.writeHead(502); res.end("{}"); });
    upstream.end(body);
  });
});
await new Promise((resolve) => shim.listen(PORT, "127.0.0.1", resolve));
const offer = store.createOffer();
const deepLink =
  `iris-link://pair?v=1&host=127.0.0.1&port=${PORT}` +
  `&secret=${encodeURIComponent(offer.secret)}&name=Harness+Mac`;
fs.writeFileSync(path.join(SCRATCH, "deeplink.txt"), deepLink);
log("LISTENING", PORT, "code", offer.code);
log("READY");
