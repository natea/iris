// Voice catalogue and English accent steering for Gemini Live.
//
// Live native-audio models pick the spoken language themselves and reject an
// explicit languageCode, and no prebuilt voice has regional variants. The only
// lever for accent is natural-language instruction, which Google's TTS guide
// says works best when the accent is described specifically (a place, not just
// "British"). GEMINI_LIVE_ACCENT holds either a preset id below or free text.

// All prebuilt voices supported by native-audio models, with Google's style
// descriptors so the Settings list is easier to choose from.
export const GEMINI_VOICES = [
  { name: "Zephyr", style: "Bright" },
  { name: "Puck", style: "Upbeat" },
  { name: "Charon", style: "Informative" },
  { name: "Kore", style: "Firm" },
  { name: "Fenrir", style: "Excitable" },
  { name: "Leda", style: "Youthful" },
  { name: "Orus", style: "Firm" },
  { name: "Aoede", style: "Breezy" },
  { name: "Callirrhoe", style: "Easy-going" },
  { name: "Autonoe", style: "Bright" },
  { name: "Enceladus", style: "Breathy" },
  { name: "Iapetus", style: "Clear" },
  { name: "Umbriel", style: "Easy-going" },
  { name: "Algieba", style: "Smooth" },
  { name: "Despina", style: "Smooth" },
  { name: "Erinome", style: "Clear" },
  { name: "Algenib", style: "Gravelly" },
  { name: "Rasalgethi", style: "Informative" },
  { name: "Laomedeia", style: "Upbeat" },
  { name: "Achernar", style: "Soft" },
  { name: "Alnilam", style: "Firm" },
  { name: "Schedar", style: "Even" },
  { name: "Gacrux", style: "Mature" },
  { name: "Pulcherrima", style: "Forward" },
  { name: "Achird", style: "Friendly" },
  { name: "Zubenelgenubi", style: "Casual" },
  { name: "Vindemiatrix", style: "Gentle" },
  { name: "Sadachbia", style: "Lively" },
  { name: "Sadaltager", style: "Knowledgeable" },
  { name: "Sulafat", style: "Warm" },
];

export const ENGLISH_ACCENTS = [
  {
    id: "british",
    label: "British (RP, London)",
    accent: "Standard Southern British English (Received Pronunciation) accent as heard in London, England",
    style: "Use British spelling, vocabulary, and phrasing (for example 'lift', 'flat', 'queue', 'mobile').",
  },
  {
    id: "scottish",
    label: "Scottish (Edinburgh)",
    accent: "Scottish English accent as heard in Edinburgh, Scotland",
    style: "Use British spelling and light, everyday Scottish-English phrasing while staying easy to understand.",
  },
  {
    id: "irish",
    label: "Irish (Dublin)",
    accent: "Irish English accent as heard in Dublin, Ireland",
    style: "Use British spelling and light, everyday Irish-English phrasing while staying easy to understand.",
  },
  {
    id: "australian",
    label: "Australian (Sydney)",
    accent: "General Australian English accent as heard in Sydney, Australia",
    style: "Use Australian spelling and vocabulary while staying easy to understand.",
  },
];

const MAX_CUSTOM_ACCENT_LENGTH = 200;

// Returns the preset for a stored value, a synthetic custom entry for free
// text, or null when no accent is configured.
export function resolveAccent(value) {
  const raw = String(value ?? "").trim();
  if (!raw) return null;
  const preset = ENGLISH_ACCENTS.find((entry) => entry.id === raw.toLowerCase());
  if (preset) return preset;
  const text = raw.replace(/\s+/g, " ").slice(0, MAX_CUSTOM_ACCENT_LENGTH);
  return { id: raw, label: `Custom: ${text}`, accent: text, style: "", custom: true };
}

// System-instruction rule for the configured accent ("" when none).
export function accentInstruction(value) {
  const entry = resolveAccent(value);
  if (!entry) return "";
  const accent = entry.custom ? `this accent: ${entry.accent}` : `a ${entry.accent}`;
  return [
    `Voice accent rule: always speak English with ${accent}.`,
    entry.style,
    "Keep this accent consistent for the whole conversation, including after interruptions, tool calls, and resumed sessions.",
  ].filter(Boolean).join(" ");
}

// Short reminder appended to injected events, where accent drift is most likely.
export function accentReminder(value) {
  const entry = resolveAccent(value);
  if (!entry) return "";
  return entry.custom
    ? `Speak with this accent: ${entry.accent}.`
    : `Speak with your ${entry.label.replace(/\s*\(.*\)$/, "")} accent.`;
}

// Settings dropdown options; keeps a saved custom value selectable.
export function accentOptions(current) {
  const options = [
    { value: "", label: "Default (model chooses)" },
    ...ENGLISH_ACCENTS.map((entry) => ({ value: entry.id, label: entry.label })),
  ];
  const entry = resolveAccent(current);
  if (entry?.custom) options.push({ value: entry.id, label: entry.label });
  return options;
}

// Case-insensitive lookup against the canonical voice catalogue.
// Returns: null when nothing was supplied (caller should fall back to a
// default), the canonical (correctly-cased) name on a match, or undefined
// when a name was supplied but matches nothing — callers treat that as
// invalid input, never as "not supplied".
export function normalizeVoiceName(value) {
  const raw = String(value ?? "").trim();
  if (!raw) return null;
  const match = GEMINI_VOICES.find((voice) => voice.name.toLowerCase() === raw.toLowerCase());
  return match ? match.name : undefined;
}

export function voiceOptions(current) {
  const options = GEMINI_VOICES.map((voice) => ({
    value: voice.name,
    label: `${voice.name} · ${voice.style}`,
  }));
  if (current && !GEMINI_VOICES.some((voice) => voice.name === current)) {
    options.unshift({ value: current, label: current });
  }
  return options;
}
