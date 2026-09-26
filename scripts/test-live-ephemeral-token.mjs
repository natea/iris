// Task 1.2: mint an ephemeral auth token (ai.authTokens.create) and connect
// to the Live API using ONLY that token — verify the session opens, and that
// the token is refused (a) on reuse past its `uses` limit and (b) after its
// newSessionExpireTime has passed. Run directly with node; makes real API
// calls against GEMINI_API_KEY.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { GoogleGenAI } from "@google/genai";

function loadApiKey() {
  const fromEnv = (process.env.GEMINI_API_KEY || "").trim();
  if (fromEnv) return fromEnv;
  const envPath = path.join(os.homedir(), ".iris", ".env");
  let text = "";
  try {
    text = fs.readFileSync(envPath, "utf8");
  } catch {
    return "";
  }
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim();
    if (key === "GEMINI_API_KEY") return value;
  }
  return "";
}

function redact(secret) {
  if (!secret) return "(empty)";
  return `len=${secret.length} prefix=${secret.slice(0, 6)}…`;
}

const apiKey = loadApiKey();
if (!apiKey) {
  console.error("FAIL: no GEMINI_API_KEY found (checked process.env and ~/.iris/.env)");
  process.exit(1);
}
console.log(`Loaded API key: ${redact(apiKey)}`);

const model = process.env.GEMINI_LIVE_MODEL || "models/gemini-3.1-flash-live-preview";

// Ephemeral tokens require v1alpha (per the JS SDK's Tokens.create docstring).
const adminAi = new GoogleGenAI({ apiKey, httpOptions: { apiVersion: "v1alpha" } });

function connectLiveWithTimeout(connectionPromise, timeoutMs, label) {
  return new Promise((resolve, reject) => {
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      reject(new Error(`${label} timed out after ${timeoutMs}ms.`));
    }, timeoutMs);
    connectionPromise.then(
      (session) => {
        clearTimeout(timer);
        if (timedOut) {
          try { session?.close(); } catch { /* already timed out */ }
          return;
        }
        resolve(session);
      },
      (error) => {
        clearTimeout(timer);
        if (!timedOut) reject(error);
      },
    );
  });
}

async function tryOpenSession(token, { label, expectFailure }) {
  const ai = new GoogleGenAI({ apiKey: token, httpOptions: { apiVersion: "v1alpha" } });
  const events = [];
  let resolveOpen;
  let resolveClose;
  const openedOrFailed = new Promise((resolve) => { resolveOpen = resolve; });
  const closed = new Promise((resolve) => { resolveClose = resolve; });

  let session = null;
  let connectError = null;
  try {
    session = await connectLiveWithTimeout(
      ai.live.connect({
        model,
        config: { responseModalities: ["AUDIO"] },
        callbacks: {
          onopen() {
            events.push({ type: "open" });
            resolveOpen({ opened: true });
          },
          onmessage(message) {
            events.push({ type: "message", message });
          },
          onerror(error) {
            events.push({ type: "error", message: error?.message || String(error) });
            resolveOpen({ opened: false, error: error?.message || String(error) });
          },
          onclose(event) {
            events.push({ type: "close", code: event?.code, reason: event?.reason });
            resolveOpen({ opened: false, closeCode: event?.code, closeReason: event?.reason });
            resolveClose({ code: event?.code, reason: event?.reason });
          },
        },
      }),
      15000,
      label,
    );
  } catch (error) {
    connectError = error;
  }

  if (connectError) {
    return { events, opened: false, connectError: connectError.message || String(connectError) };
  }

  const openResult = await Promise.race([
    openedOrFailed,
    new Promise((resolve) => setTimeout(() => resolve({ opened: false, timedOut: true }), 15000)),
  ]);

  if (openResult.opened && expectFailure) {
    // The server may accept the handshake but revoke shortly after for an
    // invalid/expired/reused token. Give it a few seconds to close on its own,
    // and also try to actually use the session — a truly refused token should
    // not produce real content.
    const closedSoon = await Promise.race([
      closed,
      new Promise((resolve) => setTimeout(() => resolve(null), 5000)),
    ]);
    if (closedSoon) {
      return { events, opened: false, closedAfterOpen: closedSoon };
    }
    try {
      session.sendClientContent({ turns: [{ role: "user", parts: [{ text: "Say: token works" }] }] });
    } catch (error) {
      try { session.close(); } catch { /* ignore */ }
      return { events, opened: false, sendError: error?.message || String(error) };
    }
    const gotContent = await Promise.race([
      new Promise((resolve) => {
        const check = () => {
          if (events.some((e) => e.type === "message")) resolve(true);
          else setTimeout(check, 250);
        };
        check();
      }),
      new Promise((resolve) => setTimeout(() => resolve(false), 8000)),
    ]);
    try { session.close(); } catch { /* ignore */ }
    return { events, opened: true, gotContent, note: "session opened and produced content despite expected refusal" };
  }

  if (openResult.opened && !expectFailure) {
    session.sendClientContent({ turns: [{ role: "user", parts: [{ text: "Say: token works" }] }] });
    const gotContent = await Promise.race([
      new Promise((resolve) => {
        const check = () => {
          if (events.some((e) => e.type === "message")) {
            resolve(true);
          } else {
            setTimeout(check, 250);
          }
        };
        check();
      }),
      new Promise((resolve) => setTimeout(() => resolve(false), 15000)),
    ]);
    try { session.close(); } catch { /* ignore */ }
    return { events, opened: true, gotContent };
  }

  try { session?.close(); } catch { /* ignore */ }
  return { events, opened: openResult.opened, closeInfo: openResult };
}

function futureIso(seconds) {
  return new Date(Date.now() + seconds * 1000).toISOString();
}

async function main() {
  let failures = 0;

  // --- Check 1: mint a normal single-use token and open a session with it.
  console.log("\n=== Check 1: mint token, connect, send a turn ===");
  const token1 = await adminAi.authTokens.create({
    config: {
      uses: 1,
      expireTime: futureIso(90),
      newSessionExpireTime: futureIso(45),
      liveConnectConstraints: {
        model,
        config: { responseModalities: ["AUDIO"] },
      },
    },
  });
  console.log(`Minted token1: name.len=${(token1.name || "").length}`);

  const result1 = await tryOpenSession(token1.name, { label: "check1", expectFailure: false });
  const pass1 = result1.opened && result1.gotContent;
  console.log(`Check 1 (open + turn works): ${pass1 ? "PASS" : "FAIL"}`, JSON.stringify({
    opened: result1.opened,
    gotContent: result1.gotContent,
    connectError: result1.connectError,
  }));
  if (!pass1) failures++;

  // --- Check 2: reuse the same single-use token for a second session — must be refused.
  console.log("\n=== Check 2: reuse single-use token (expect refusal) ===");
  const result2 = await tryOpenSession(token1.name, { label: "check2-reuse", expectFailure: true });
  const pass2 = !result2.opened;
  console.log(`Check 2 (reuse refused): ${pass2 ? "PASS" : "FAIL"}`, JSON.stringify({
    opened: result2.opened,
    connectError: result2.connectError,
    closeInfo: result2.closeInfo,
    closedAfterOpen: result2.closedAfterOpen,
  }));
  if (!pass2) failures++;

  // --- Check 3: mint a token with a very short newSessionExpireTime, wait past it, confirm refusal.
  console.log("\n=== Check 3: newSessionExpireTime elapses (expect refusal) ===");
  const token3 = await adminAi.authTokens.create({
    config: {
      uses: 2,
      expireTime: futureIso(60),
      newSessionExpireTime: futureIso(4),
      liveConnectConstraints: {
        model,
        config: { responseModalities: ["AUDIO"] },
      },
    },
  });
  console.log(`Minted token3: name.len=${(token3.name || "").length}. Waiting 8s for newSessionExpireTime to pass…`);
  await new Promise((resolve) => setTimeout(resolve, 8000));
  const result3 = await tryOpenSession(token3.name, { label: "check3-expired-window", expectFailure: true });
  const pass3 = !result3.opened;
  console.log(`Check 3 (post-window connect refused): ${pass3 ? "PASS" : "FAIL"}`, JSON.stringify({
    opened: result3.opened,
    connectError: result3.connectError,
    closeInfo: result3.closeInfo,
    closedAfterOpen: result3.closedAfterOpen,
  }));
  if (!pass3) failures++;

  console.log(`\n=== Summary: ${failures === 0 ? "ALL PASS" : `${failures} check(s) FAILED`} ===`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error("FAIL: uncaught error", error?.stack || error);
  process.exit(1);
});
