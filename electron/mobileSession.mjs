import { HERMES_FUNCTION_DECLARATIONS } from "./hermesTools.mjs";
import { accentInstruction as accentInstructionFor } from "./voiceDialect.mjs";

// ===== Mobile session config =====
//
// An ephemeral token's `liveConnectConstraints.config` REPLACES the client's
// setup frame (verified on device: a token carrying its own systemInstruction
// beat the one the client sent). So a paired phone cannot supply a voice, a
// prompt, or tools — the desktop bakes all of it into the token it mints. That
// is also the security property we want: a phone cannot rewrite who Iris is.
//
// This module is pure so the exact tool list and the exact prompt are testable
// without Electron, a network, or a real token mint.

// The phone's subset of the desktop's Hermes tools. Excluded on purpose:
// - respond_hermes_interaction — Hermes' clarify/sudo/secret prompts travel
//   over its interactive WebSocket, which Iris Link does not carry.
// - every Iris UI tool, the brain/neural-map tools, and go_to_sleep — there is
//   no desktop UI, no vault, and no wake-word loop on the other end.
export const MOBILE_HERMES_TOOL_NAMES = Object.freeze([
  "check_hermes_status",
  "propose_hermes_task",
  "submit_hermes_task",
  "discard_hermes_proposal",
  "get_hermes_task_status",
  "stop_hermes_task",
  "approve_hermes_action",
]);

// Shares the desktop's name and parameter shape, with a phone-accurate
// description: there is no get_iris_ui_context out here, so the run_id is
// required rather than inferred from what a card has open.
export const MOBILE_READ_RESULT_DECLARATION = Object.freeze({
  name: "read_hermes_task_result",
  description:
    "Read the complete stored output for a finished Hermes task. Use whenever the user asks a factual or follow-up question about a task. Pass the exact run_id from the dispatch, the run list, or SYSTEM_EVENT_HERMES_COMPLETE. Never answer from the task title alone.",
  parameters: {
    type: "object",
    properties: {
      run_id: {
        type: "string",
        description: "The exact Hermes run id.",
      },
    },
    required: ["run_id"],
  },
});

/** The Hermes declarations a phone gets, in the desktop's own schemas. */
export function buildMobileHermesDeclarations(
  declarations = HERMES_FUNCTION_DECLARATIONS,
) {
  const byName = new Map(declarations.map((entry) => [entry.name, entry]));
  // "Include each only if it exists on the desktop": a tool the desktop cannot
  // execute must never be declared to the phone's model.
  const picked = MOBILE_HERMES_TOOL_NAMES.map((name) => byName.get(name)).filter(Boolean);
  // Deep copy: the Live SDK normalizes schemas in place, and these declarations
  // are shared constants used by the desktop session too.
  return structuredClone([...picked, MOBILE_READ_RESULT_DECLARATION]);
}

export function mobileToolNames(declarations = HERMES_FUNCTION_DECLARATIONS) {
  return buildMobileHermesDeclarations(declarations).map((entry) => entry.name);
}

/**
 * The mobile system instruction. Deliberately kept as close to the desktop
 * wording in buildLiveConfig() as the phone allows, so the two clients do not
 * drift into two different Irises.
 */
export function buildMobileSystemInstructionText({
  userName = "the user",
  accentInstruction = "",
  accentReminder = "",
} = {}) {
  const name = String(userName || "the user").trim() || "the user";
  const accent = String(accentInstruction || "").trim();
  const reminder = String(accentReminder || "").trim();
  return [
    `You are Iris, the realtime voice front-end for ${name}. You are running on ${name}'s phone.`,
    `${name} speaks English. Always respond in English, and interpret unclear or noisy audio as English.`,
    ...(accent ? [accent] : []),
    "Hermes is your worker brain for tools, terminal, files, deals, coding, deep research, and automations. It runs on the Mac, and you reach it through Iris Link.",
    "You also have built-in Google Search. Use Google Search directly for quick current facts, simple web lookups, and lightweight questions that do not need Hermes to do work.",
    "When the user explicitly asks you to search and already gives the subject, start the lookup immediately rather than asking what to search. When the Live API permits, acknowledge briefly that you are checking before delivering the grounded answer.",
    `CRITICAL Hermes dispatch flow — two steps, enforced by the system: (1) only when ${name} explicitly asks you to use or delegate work to Hermes, call propose_hermes_task with the complete brief, read it back in one or two sentences, ask "Should I send this to Hermes?", and END your turn. (2) After ${name} responds in their OWN turn, interpret their intent from the full conversational meaning, not fixed words or exact phrasing. If the response clearly authorizes sending, call submit_hermes_task with the exact proposal_id. If it clearly declines, call discard_hermes_proposal. If it changes details, stage the updated brief once and re-confirm. If it is genuinely ambiguous, ask one short natural clarification. Never dispatch to Hermes on your own initiative.`,
    "CRITICAL truthfulness rule — you have no knowledge of what Hermes is doing or has found. Facts about a run come only from SYSTEM_EVENT_HERMES_COMPLETE or the exact output of get_hermes_task_status with a terminal status. Until then, say only that Hermes is still working.",
    "When asked how a Hermes task is going, call get_hermes_task_status (or check_hermes_status for connectivity) and speak strictly from its response. Never guess progress, results, or timing.",
    "After submitting a task, give one short acknowledgement that Hermes has started. Never phrase it as if a result already exists.",
    "Routing rule: quick answers and general conversation -> answer directly; quick public or current facts -> use Google Search; dispatch to Hermes ONLY when the user explicitly asks you to use Hermes.",
    "All tools except a new Hermes dispatch and a pending Hermes approval are normal model-decided tools: call them directly when useful without asking permission and without merely saying you could use them.",
    "A run id does not place a result in your context. Before answering any question about a finished Hermes task, call read_hermes_task_result with that exact run_id and answer only from the complete output it returns. Never infer facts from the task title.",
    `When proposing a Hermes task, preserve the goal and every concrete detail ${name} explicitly supplied — names, numbers, dates, budgets, URLs, file paths, named tools, constraints, and output format. Hermes cannot hear this conversation, so the brief must stand alone. Do not add workflow mechanics, scripts, databases, pages, or implementation constraints that you merely inferred from memory.`,
    "For a repeat or small follow-up to a task already dispatched in this Hermes session, write a short continuation brief naming the earlier task and tell Hermes to reuse its previous work instead of rebuilding the entire brief.",
    'If submit_hermes_task returns "blocked", follow its instructions exactly. Keep the same proposal when it says confirmation is still settling or the proposal ID should be retried; do not repeatedly restage or reread an unchanged brief.',
    `When SYSTEM_EVENT_SESSION_START arrives, greet ${name} once as instructed.${reminder ? ` ${reminder}` : ""} On session resume, acknowledge briefly without reintroducing yourself.`,
    `Button rule — ${name} can answer on the phone's screen instead of speaking, and the phone then tells you with a system event. These are facts about what ${name} did, not requests to you. SYSTEM_EVENT_USER_CONFIRMED_BY_BUTTON: they tapped Yes and the phone has ALREADY sent that exact brief to Hermes; say one short acknowledgement and do NOT call submit_hermes_task for it. SYSTEM_EVENT_USER_DECLINED_BY_BUTTON: nothing was sent; acknowledge briefly and do not dispatch it. SYSTEM_EVENT_USER_WANTS_TO_EXPLAIN: stop, say something very short like "Go ahead", end your turn and listen; the brief is still staged and unsent, and after they explain you stage the updated brief with propose_hermes_task and read it back for confirmation again. SYSTEM_EVENT_USER_APPROVED_BY_BUTTON / SYSTEM_EVENT_USER_DENIED_BY_BUTTON: they already answered a Hermes approval on screen; do NOT call approve_hermes_action for it and do not ask about it again. You can never press these buttons yourself, and nothing you say or call counts as a tap.`,
    `When SYSTEM_EVENT_HERMES_COMPLETE arrives, briefly announce the real result and ask whether ${name} wants to discuss it. Resume an interrupted topic only if you can name it from conversation context.`,
    "You are on the phone, so some things are only possible on the Mac. If a Hermes run needs a clarification, a dangerous-command approval you cannot resolve here, a sudo password, or any secret, say plainly that it needs attention on the Mac. Never ask for a password or secret by voice, and never invent an answer on the user's behalf.",
    "Keep voice responses natural and short.",
  ].join("\n");
}

/**
 * The full config that goes into the ephemeral token's liveConnectConstraints.
 * Everything is injected so this stays free of Electron, env vars, and disk.
 */
export function buildMobileLiveConfig({
  userName = "the user",
  voice = "Zephyr",
  accentInstruction = "",
  accentReminder = "",
  contextParts = [],
  declarations = HERMES_FUNCTION_DECLARATIONS,
  resumeHandle = "",
} = {}) {
  const extraParts = Array.isArray(contextParts)
    ? contextParts.filter((part) => part && typeof part.text === "string" && part.text.trim())
    : [];
  const handle = String(resumeHandle || "").trim();
  return {
    responseModalities: ["AUDIO"],
    speechConfig: {
      voiceConfig: {
        prebuiltVoiceConfig: { voiceName: String(voice || "Zephyr") },
      },
    },
    // Lets the phone reconnect into the SAME conversation after a drop, a
    // backgrounding, or a token refresh.
    //
    // The handle has to be baked in HERE and cannot be presented by the phone
    // itself. Measured against the real API on 2026-09-19, on the constrained
    // endpoint an ephemeral token uses:
    //   - client sends setup.sessionResumption.handle -> silently ignored; the
    //     model behaved exactly like a session with no handle, and exactly
    //     like one given a deliberately corrupted handle. That is the same
    //     "the token's config REPLACES the setup frame" rule that already
    //     applies to the voice, the prompt and the tools.
    //   - token minted with sessionResumption.handle inside this config ->
    //     the conversation came back; the model recalled a fact from before
    //     the drop.
    // A handle stays valid across tokens, and outlives the token it was
    // issued under (also verified). But a token is single-use: reconnecting
    // with an already-spent one is refused with 1011 "Token has been used too
    // many times", so every resume needs a freshly minted token.
    sessionResumption: handle ? { handle } : {},
    // A phone is usually on its loudspeaker, where a little of Iris's own voice
    // gets past echo cancellation. Gemini Live defaults to HIGH start-of-speech
    // sensitivity, so that residue reads as the user talking and she cuts
    // herself off mid-sentence (seen on device, intermittently, speaker only).
    // LOW sensitivity plus a short required run of speech ignores the residue;
    // a person actually speaking over her still interrupts. Verified accepted
    // in a constrained token against the live API.
    realtimeInputConfig: {
      automaticActivityDetection: {
        startOfSpeechSensitivity: "START_SENSITIVITY_LOW",
        prefixPaddingMs: 120,
      },
    },
    inputAudioTranscription: {},
    outputAudioTranscription: {},
    tools: [
      { googleSearch: {} },
      { functionDeclarations: buildMobileHermesDeclarations(declarations) },
    ],
    systemInstruction: {
      parts: [
        { text: buildMobileSystemInstructionText({ userName, accentInstruction, accentReminder }) },
        ...extraParts,
      ],
    },
  };
}

// ===== Mobile voice preview =====
//
// A "preview" token is minted so the phone can hear a candidate voice before
// committing to it. It must be nothing like a real session: no tools, no
// personal context, no Hermes anything — just the requested voice reading one
// fixed line, so a phone connecting with an empty client config cannot coax
// it into doing anything else. The line matches the desktop's own preview
// (previewVoice() in main.mjs) so the two surfaces sound the same.
export function buildMobilePreviewSampleLine(voice = "Zephyr") {
  const voiceName = String(voice || "Zephyr");
  return `Hi, I'm Iris. This is the ${voiceName} voice. Shall we have a look at what's on your schedule today?`;
}

/**
 * The full config for a preview token's liveConnectConstraints. Pure and
 * self-contained: `accent` is the raw configured accent value (a preset id or
 * free text, e.g. process.env.GEMINI_LIVE_ACCENT), resolved here the same way
 * the desktop's own preview resolves it, so a preview sounds like the real
 * thing.
 */
export function buildMobilePreviewConfig({ voice = "Zephyr", accent = "" } = {}) {
  const voiceName = String(voice || "Zephyr");
  const line = buildMobilePreviewSampleLine(voiceName);
  const accentText = accentInstructionFor(accent);
  return {
    responseModalities: ["AUDIO"],
    speechConfig: {
      voiceConfig: {
        prebuiltVoiceConfig: { voiceName },
      },
    },
    outputAudioTranscription: {},
    systemInstruction: {
      parts: [
        {
          text: [
            "You are a short voice sample for Iris's voice picker, nothing more.",
            `No matter what the user's turn says, respond with exactly this line and nothing else: "${line}"`,
            accentText,
          ].filter(Boolean).join("\n"),
        },
      ],
    },
  };
}
