// Throwaway E2E harness. Runs the REAL Iris Link server (electron/irisLinkServer.mjs
// + electron/pairingStore.mjs) on 127.0.0.1, mints REAL ephemeral tokens with the
// real mobile config builder (electron/mobileSession.mjs), and wires FAKE task
// handlers so no actual Hermes work is dispatched.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { GoogleGenAI } from "../../../node_modules/@google/genai/dist/node/index.mjs";
import { createIrisLinkServer } from "../../../electron/irisLinkServer.mjs";
import { createPairingStore } from "../../../electron/pairingStore.mjs";
import { buildMobileLiveConfig } from "../../../electron/mobileSession.mjs";

const SCRATCH = process.env.SCRATCH || fs.mkdtempSync(path.join(os.tmpdir(), "iris-link-harness-"));
const PORT = Number(process.env.PORT || 8799);
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
    const token = await ai.authTokens.create({
      config: {
        uses: 1,
        expireTime: expiresAt,
        newSessionExpireTime: newSessionExpiresAt,
        liveConnectConstraints: {
          model: MODEL,
          config: buildMobileLiveConfig({ userName: USER, voice: "Zephyr" }),
        },
      },
    });
    log("MINTED_TOKEN");
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

await server.listen({ host: "127.0.0.1", port: PORT });
const offer = store.createOffer();
const deepLink =
  `iris-link://pair?v=1&host=127.0.0.1&port=${PORT}` +
  `&secret=${encodeURIComponent(offer.secret)}&name=Harness+Mac`;
fs.writeFileSync(path.join(SCRATCH, "deeplink.txt"), deepLink);
log("LISTENING", PORT, "code", offer.code);
log("READY");
