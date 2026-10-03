import path from "node:path";

// Obsidian's URI scheme (https://obsidian.md/help/Extending+Obsidian/Obsidian+URI)
// is how a Hermes result points at a note, image or video in the brain vault.
// The same `obsidian://open?vault=…&file=…` link works in Obsidian on the Mac
// and on the phone, as long as the file has synced to both.

// Only these actions may leave Iris. `new`, `hook-get-address` and plugin
// actions can write to the vault or leak data, and Hermes output is untrusted.
const SAFE_OBSIDIAN_ACTIONS = new Set(["open", "search"]);

export function safeObsidianUrl(value) {
  try {
    const url = new URL(String(value || ""));
    if (url.protocol !== "obsidian:") return null;
    // obsidian://open?… parses with the action as the host.
    return SAFE_OBSIDIAN_ACTIONS.has(url.hostname.toLowerCase()) ? url.toString() : null;
  } catch {
    return null;
  }
}

// Obsidian names a vault after its folder, so "~/Documents/Obsidian Vault"
// is the vault "Obsidian Vault".
export function vaultNameFromPath(vaultRoot) {
  if (!String(vaultRoot || "").trim()) return null;
  return path.basename(path.resolve(String(vaultRoot))) || null;
}

// A vault-relative path with forward slashes, or null when the file is
// outside the vault (Obsidian cannot open it, and the phone will not have it).
export function vaultRelativePath(vaultRoot, filePath) {
  if (!vaultRoot || !filePath) return null;
  const root = path.resolve(vaultRoot);
  const full = path.resolve(root, String(filePath));
  const relative = path.relative(root, full);
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) return null;
  return relative.split(path.sep).join("/");
}

// Obsidian wants every value percent-encoded, including "/" (%2F) and
// spaces (%20, never "+"), which is exactly encodeURIComponent.
export function obsidianOpenUri({ vault, file }) {
  if (!vault || !file) return null;
  return `obsidian://open?vault=${encodeURIComponent(vault)}&file=${encodeURIComponent(file)}`;
}

export function obsidianUriForPath(vaultRoot, filePath) {
  const file = vaultRelativePath(vaultRoot, filePath);
  return file ? obsidianOpenUri({ vault: vaultNameFromPath(vaultRoot), file }) : null;
}

// Appended to the per-run Hermes instructions so results link into the vault
// instead of printing bare paths.
export function vaultLinkInstructions(vaultRoot) {
  const vault = vaultNameFromPath(vaultRoot);
  if (!vault) return "";
  const example = obsidianOpenUri({ vault, file: "1-Projects/Example Note.md" });
  return (
    `Linking to files: the user reads your result on a Mac and an iPhone, where Markdown links are tappable but bare paths are not. ` +
    `The user's Obsidian vault "${vault}" lives at ${path.resolve(vaultRoot)} and syncs to both devices. ` +
    `When you mention a note, image, video, PDF or other file INSIDE that vault, write it as a Markdown link to an Obsidian URI: ` +
    `[Example Note](${example}) — vault=${encodeURIComponent(vault)}, file=the path relative to the vault root, both percent-encoded ` +
    `(space as %20, "/" as %2F; the .md extension may be dropped). ` +
    `For a file OUTSIDE the vault, give its absolute path in backticks and say it is only on the Mac. ` +
    `Web pages stay ordinary https links. Never invent a link to a file you have not confirmed exists.`
  );
}
