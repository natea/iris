import { defaultUrlTransform } from "react-markdown";

// react-markdown blanks every href whose scheme is not http(s)/mailto/etc, so
// a Hermes link into the Obsidian vault would render as a dead link. Let
// obsidian:// through; the main process still decides what may actually open
// (see safeExternalUrl in electron/windowSecurity.mjs).
export function irisUrlTransform(url: string): string {
  return /^obsidian:/i.test(url) ? url : defaultUrlTransform(url);
}
