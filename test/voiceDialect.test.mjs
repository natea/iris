import test from "node:test";
import assert from "node:assert/strict";
import {
  GEMINI_VOICES,
  ENGLISH_ACCENTS,
  accentInstruction,
  accentOptions,
  accentReminder,
  resolveAccent,
  voiceOptions,
} from "../electron/voiceDialect.mjs";

test("no accent configured produces no instruction", () => {
  for (const value of [undefined, null, "", "   "]) {
    assert.equal(resolveAccent(value), null);
    assert.equal(accentInstruction(value), "");
    assert.equal(accentReminder(value), "");
  }
});

test("presets resolve case-insensitively into specific accent instructions", () => {
  const instruction = accentInstruction("British");
  assert.match(instruction, /Received Pronunciation/);
  assert.match(instruction, /London, England/);
  assert.match(instruction, /British spelling/);
  assert.match(instruction, /consistent/);
  assert.equal(accentReminder("british"), "Speak with your British accent.");
  for (const entry of ENGLISH_ACCENTS) {
    assert.equal(resolveAccent(entry.id), entry);
  }
});

test("the American preset steers explicitly instead of relying on the model's default", () => {
  const instruction = accentInstruction("american");
  assert.match(instruction, /General American/);
  assert.match(instruction, /American spelling/);
  assert.equal(accentReminder("american"), "Speak with your American accent.");
});

test("free text is treated as a custom accent, normalized and capped", () => {
  const entry = resolveAccent("  Yorkshire English,\n as heard in Leeds ");
  assert.equal(entry.custom, true);
  assert.equal(entry.accent, "Yorkshire English, as heard in Leeds");
  assert.match(accentInstruction("Yorkshire English, as heard in Leeds"), /this accent: Yorkshire English/);
  assert.equal(resolveAccent("x".repeat(500)).accent.length, 200);
});

test("accent options keep a saved custom value selectable", () => {
  assert.deepEqual(accentOptions("").map((option) => option.value), ["", ...ENGLISH_ACCENTS.map((e) => e.id)]);
  const options = accentOptions("Welsh English as heard in Cardiff");
  assert.equal(options.at(-1).value, "Welsh English as heard in Cardiff");
  assert.equal(options.at(-1).label, "Custom: Welsh English as heard in Cardiff");
});

test("voice catalogue lists all 30 unique voices and keeps unknown saved voices", () => {
  assert.equal(GEMINI_VOICES.length, 30);
  assert.equal(new Set(GEMINI_VOICES.map((voice) => voice.name)).size, 30);
  assert.equal(voiceOptions("Iapetus").find((o) => o.value === "Iapetus").label, "Iapetus · Clear");
  assert.equal(voiceOptions("FutureVoice")[0].value, "FutureVoice");
});
