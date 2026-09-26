// What "today" and "tomorrow" mean to the person Iris is talking to.
//
// A Live session is never told the date, so the model falls back on UTC. At
// 9 pm US Eastern on a Sunday, UTC is already Monday — and "my schedule
// tomorrow" was dispatched to Hermes as Tuesday (seen on device). The model
// cannot know the user's clock unless it is stated, so it is stated, in words,
// at the start of every session.

// Returns the zone if Intl accepts it, otherwise "". Never trust a client string.
export function normalizeTimeZone(value) {
  const zone = String(value ?? "").trim();
  if (!zone || zone.length > 64 || !/^[A-Za-z0-9_+\-/]+$/.test(zone)) return "";
  try {
    return new Intl.DateTimeFormat("en-US", { timeZone: zone }).resolvedOptions().timeZone;
  } catch {
    return "";
  }
}

export function systemTimeZone() {
  try {
    return new Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  } catch {
    return "UTC";
  }
}

function parts(date, timeZone, options) {
  return new Intl.DateTimeFormat("en-US", { timeZone, ...options }).format(date);
}

function longDate(date, timeZone) {
  return parts(date, timeZone, { weekday: "long", year: "numeric", month: "long", day: "numeric" });
}

// The rule the model is given. Tomorrow and yesterday are spelled out rather
// than left to arithmetic: "tomorrow" is the word that went wrong.
export function localTimeInstruction({ now = new Date(), timeZone = "", userName = "the user" } = {}) {
  const zone = normalizeTimeZone(timeZone) || systemTimeZone();
  const day = 24 * 60 * 60 * 1000;
  // Noon-anchored so a DST change cannot skip or repeat a calendar day.
  const noon = new Date(now.getTime());
  const hourHere = Number(parts(now, zone, { hour: "numeric", hour12: false })) % 24;
  noon.setTime(now.getTime() + (12 - hourHere) * 60 * 60 * 1000);
  const time = parts(now, zone, { hour: "numeric", minute: "2-digit" });
  const zoneName = parts(now, zone, { timeZoneName: "short" }).split(", ").pop();
  return [
    `Date and time rule: it is ${time} on ${longDate(now, zone)} where ${userName} is (time zone ${zone}, ${zoneName}).`,
    `Today is ${longDate(noon, zone)}. Tomorrow is ${longDate(new Date(noon.getTime() + day), zone)}. Yesterday was ${longDate(new Date(noon.getTime() - day), zone)}.`,
    `Always resolve "today", "tomorrow", "tonight", "this week", weekdays, and times in THIS time zone, never in UTC. When a Hermes brief involves a date or time, write the full local date and the time zone into the brief.`,
  ].join(" ");
}
