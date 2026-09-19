import test from "node:test";
import assert from "node:assert/strict";
import { HERMES_FUNCTION_DECLARATIONS } from "../electron/hermesTools.mjs";
import {
  MOBILE_HERMES_TOOL_NAMES,
  buildMobileHermesDeclarations,
  buildMobileLiveConfig,
  buildMobilePreviewConfig,
  buildMobilePreviewSampleLine,
  buildMobileSystemInstructionText,
  mobileToolNames,
} from "../electron/mobileSession.mjs";

// The mobile config is baked into the ephemeral token and REPLACES whatever the
// phone sends, so what is asserted here is exactly what a paired phone gets.
const EXPECTED_TOOLS = [
  "check_hermes_status",
  "propose_hermes_task",
  "submit_hermes_task",
  "discard_hermes_proposal",
  "get_hermes_task_status",
  "stop_hermes_task",
  "approve_hermes_action",
  "read_hermes_task_result",
];

test("the mobile config declares exactly the intended tools", () => {
  const config = buildMobileLiveConfig({ userName: "Nate" });
  assert.deepEqual(config.tools[0], { googleSearch: {} });
  assert.deepEqual(config.tools[1].functionDeclarations.map((entry) => entry.name), EXPECTED_TOOLS);
  assert.equal(config.tools.length, 2);
  assert.deepEqual(mobileToolNames(), EXPECTED_TOOLS);
});

test("no UI, brain, sleep, or interactive tools reach the phone", () => {
  const names = new Set(mobileToolNames());
  for (const forbidden of [
    "control_iris_ui",
    "get_iris_ui_context",
    "go_to_sleep",
    "search_brain",
    "search_memory",
    "read_memory_note",
    // Hermes' clarify/sudo/secret prompts ride its interactive WebSocket,
    // which Iris Link does not carry.
    "respond_hermes_interaction",
  ]) {
    assert.equal(names.has(forbidden), false, `${forbidden} must not be declared on the phone`);
  }
});

test("the mobile tools reuse the desktop schemas, name for name", () => {
  const desktop = new Map(HERMES_FUNCTION_DECLARATIONS.map((entry) => [entry.name, entry]));
  for (const declaration of buildMobileHermesDeclarations()) {
    if (declaration.name === "read_hermes_task_result") continue;
    assert.deepEqual(declaration, desktop.get(declaration.name), declaration.name);
  }
  // read_hermes_task_result exists on the desktop as a UI tool; on the phone
  // there is no UI context to infer a run id from, so run_id is required.
  const readResult = buildMobileHermesDeclarations().at(-1);
  assert.equal(readResult.name, "read_hermes_task_result");
  assert.deepEqual(readResult.parameters.required, ["run_id"]);
  assert.deepEqual(Object.keys(readResult.parameters.properties), ["run_id"]);
});

test("a tool missing from the desktop is never declared to the phone", () => {
  const withoutStop = HERMES_FUNCTION_DECLARATIONS.filter(
    (entry) => entry.name !== "stop_hermes_task",
  );
  const names = buildMobileHermesDeclarations(withoutStop).map((entry) => entry.name);
  assert.equal(names.includes("stop_hermes_task"), false);
  assert.equal(names.includes("submit_hermes_task"), true);
  assert.ok(MOBILE_HERMES_TOOL_NAMES.includes("stop_hermes_task"));
});

test("the declarations handed out are copies, not the shared constants", () => {
  const first = buildMobileHermesDeclarations();
  first[0].parameters.mutated = true;
  const second = buildMobileHermesDeclarations();
  assert.equal(second[0].parameters.mutated, undefined);
  assert.equal(HERMES_FUNCTION_DECLARATIONS[0].parameters.mutated, undefined);
});

test("the prompt carries the dispatch, truthfulness, and English rules", () => {
  const text = buildMobileSystemInstructionText({ userName: "Nate" });
  assert.match(text, /CRITICAL Hermes dispatch flow — two steps/);
  assert.match(text, /propose_hermes_task with the complete brief/);
  assert.match(text, /submit_hermes_task with the exact proposal_id/);
  assert.match(text, /discard_hermes_proposal/);
  assert.match(text, /CRITICAL truthfulness rule/);
  assert.match(text, /Never dispatch to Hermes on your own initiative/);
  assert.match(text, /Nate speaks English\. Always respond in English/);
  assert.match(text, /interpret unclear or noisy audio as English/);
  assert.match(text, /You are running on Nate's phone/);
  assert.match(text, /SYSTEM_EVENT_SESSION_START/);
  assert.match(text, /SYSTEM_EVENT_HERMES_COMPLETE/);
  assert.match(text, /needs attention on the Mac|attention on the Mac/);
  assert.match(text, /"blocked"/);
  assert.match(text, /Keep voice responses natural and short/);
  assert.match(text, /the brief must stand alone/);
  assert.match(text, /get_hermes_task_status/);
});

test("the prompt leaves the desktop-only surfaces out", () => {
  const text = buildMobileSystemInstructionText({ userName: "Nate" });
  for (const absent of ["Neural Map", "HUD rule", "control_iris_ui", "go_to_sleep", "Sleep rule"]) {
    assert.equal(text.includes(absent), false, `${absent} should not be in the mobile prompt`);
  }
});

test("the accent hook is optional and appears verbatim when set", () => {
  const without = buildMobileSystemInstructionText({ userName: "Nate" });
  assert.equal(without.includes("accent"), false);
  const withAccent = buildMobileSystemInstructionText({
    userName: "Nate",
    accentInstruction: "Speak English with a British accent.",
  });
  assert.match(withAccent, /Speak English with a British accent\./);
});

test("voice, resumption, and transcription are baked in, and context is appended", () => {
  const config = buildMobileLiveConfig({
    userName: "Nate",
    voice: "Charon",
    contextParts: [{ text: "USER CONTEXT — lives in Boston." }, { text: "   " }, null],
  });
  assert.deepEqual(config.responseModalities, ["AUDIO"]);
  assert.equal(config.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName, "Charon");
  // Verified accepted by the real token endpoint; a rejected field would break
  // every phone session.
  assert.deepEqual(config.sessionResumption, {});
  assert.deepEqual(config.inputAudioTranscription, {});
  assert.deepEqual(config.outputAudioTranscription, {});
  assert.equal(config.systemInstruction.parts.length, 2);
  assert.equal(config.systemInstruction.parts[1].text, "USER CONTEXT — lives in Boston.");
});

test("a resume handle is baked into the token's config, because the phone cannot present one", () => {
  // Measured against the real API: on the constrained endpoint a handle the
  // phone puts in its own setup frame is silently ignored — the token's config
  // replaces it, exactly as it replaces the voice and the prompt. Baking it in
  // here is the ONLY thing that reconnects into the same conversation.
  const resumed = buildMobileLiveConfig({ userName: "Nate", resumeHandle: "handle-abc" });
  assert.deepEqual(resumed.sessionResumption, { handle: "handle-abc" });
  // Everything else is untouched: a resumed session is the same Iris.
  const fresh = buildMobileLiveConfig({ userName: "Nate" });
  assert.deepEqual(
    { ...resumed, sessionResumption: null },
    { ...fresh, sessionResumption: null },
  );
});

test("a blank resume handle asks for a fresh conversation rather than a broken one", () => {
  for (const value of ["", "   ", null, undefined]) {
    const config = buildMobileLiveConfig({ userName: "Nate", resumeHandle: value });
    assert.deepEqual(config.sessionResumption, {});
  }
});

test("a missing user name degrades to a neutral one rather than 'undefined'", () => {
  const text = buildMobileSystemInstructionText({});
  assert.equal(text.includes("undefined"), false);
  assert.match(text, /the user/);
});

test("the accent reminder is optional and lands in the session-start guidance when set", () => {
  const without = buildMobileSystemInstructionText({ userName: "Nate" });
  assert.match(without, /When SYSTEM_EVENT_SESSION_START arrives, greet Nate once as instructed\. On session resume/);

  const withReminder = buildMobileSystemInstructionText({
    userName: "Nate",
    accentReminder: "Speak with your British accent.",
  });
  assert.match(
    withReminder,
    /greet Nate once as instructed\. Speak with your British accent\. On session resume/,
  );
});

test("buildMobileLiveConfig threads the accent reminder into the system instruction", () => {
  const config = buildMobileLiveConfig({
    userName: "Nate",
    accentInstruction: "Voice accent rule: always speak English with a Scottish accent.",
    accentReminder: "Speak with your Scottish accent.",
  });
  const text = config.systemInstruction.parts[0].text;
  assert.match(text, /Voice accent rule: always speak English with a Scottish accent\./);
  assert.match(text, /Speak with your Scottish accent\./);
});

test("buildMobilePreviewSampleLine reuses the desktop's preview sentence", () => {
  assert.equal(
    buildMobilePreviewSampleLine("Algenib"),
    "Hi, I'm Iris. This is the Algenib voice. Shall we have a look at what's on your schedule today?",
  );
});

test("buildMobilePreviewConfig is minimal: no tools, no context, the fixed line, the requested voice", () => {
  const config = buildMobilePreviewConfig({ voice: "Algenib" });
  assert.deepEqual(config.responseModalities, ["AUDIO"]);
  assert.equal(config.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName, "Algenib");
  assert.deepEqual(config.outputAudioTranscription, {});
  assert.equal(config.tools, undefined);
  assert.equal(config.inputAudioTranscription, undefined);
  assert.equal(config.sessionResumption, undefined);
  assert.equal(config.systemInstruction.parts.length, 1);
  const text = config.systemInstruction.parts[0].text;
  assert.match(
    text,
    /Hi, I'm Iris\. This is the Algenib voice\. Shall we have a look at what's on your schedule today\?/,
  );
  // No Hermes, no personal context — just the sample line and voice.
  assert.equal(text.includes("Hermes"), false);
  assert.equal(text.includes("USER CONTEXT"), false);
});

test("buildMobilePreviewConfig includes the configured accent instruction", () => {
  const withAccent = buildMobilePreviewConfig({ voice: "Zephyr", accent: "british" });
  const text = withAccent.systemInstruction.parts[0].text;
  assert.match(text, /Voice accent rule: always speak English with a Standard Southern British English/);

  const withoutAccent = buildMobilePreviewConfig({ voice: "Zephyr" });
  assert.equal(withoutAccent.systemInstruction.parts[0].text.includes("Voice accent rule"), false);
});
