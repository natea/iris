import test from "node:test";
import assert from "node:assert/strict";
import {
  obsidianOpenUri,
  obsidianUriForPath,
  safeObsidianUrl,
  vaultLinkInstructions,
  vaultNameFromPath,
  vaultRelativePath,
} from "../electron/vaultLinks.mjs";
import { safeExternalUrl } from "../electron/windowSecurity.mjs";

const VAULT = "/Users/nate/Documents/Obsidian Vault/";

test("the vault name is the vault folder's name", () => {
  assert.equal(vaultNameFromPath(VAULT), "Obsidian Vault");
});

test("Obsidian URIs percent-encode spaces and slashes the way Obsidian expects", () => {
  assert.equal(
    obsidianOpenUri({ vault: "Obsidian Vault", file: "1-Projects/Trip & Plans.md" }),
    "obsidian://open?vault=Obsidian%20Vault&file=1-Projects%2FTrip%20%26%20Plans.md",
  );
  assert.equal(obsidianOpenUri({ vault: "Obsidian Vault", file: "" }), null);
});

test("only files inside the vault get an Obsidian link", () => {
  assert.equal(
    obsidianUriForPath(VAULT, "/Users/nate/Documents/Obsidian Vault/thumbnails/clip one.mp4"),
    "obsidian://open?vault=Obsidian%20Vault&file=thumbnails%2Fclip%20one.mp4",
  );
  assert.equal(vaultRelativePath(VAULT, "Daily/2026-09-25.md"), "Daily/2026-09-25.md");
  assert.equal(obsidianUriForPath(VAULT, "/Users/nate/Movies/clip.mp4"), null);
  assert.equal(obsidianUriForPath(VAULT, "../Obsidian Vault 2/secret.md"), null);
  assert.equal(obsidianUriForPath(VAULT, VAULT), null);
});

test("only read-only Obsidian actions may be opened", () => {
  const open = "obsidian://open?vault=Obsidian%20Vault&file=Note";
  assert.equal(safeObsidianUrl(open), open);
  assert.equal(safeExternalUrl(open), open);
  assert.ok(safeExternalUrl("obsidian://search?vault=Obsidian%20Vault&query=iris"));
  assert.equal(safeExternalUrl("obsidian://new?vault=V&file=x&content=y&overwrite=true"), null);
  assert.equal(safeExternalUrl("obsidian://hook-get-address"), null);
  assert.equal(safeExternalUrl("obsidian://advanced-uri?vault=V&commandid=x"), null);
  assert.equal(safeExternalUrl("file:///Applications/Calculator.app"), null);
});

test("the Hermes guidance names the vault and a correctly encoded example", () => {
  const text = vaultLinkInstructions(VAULT);
  assert.match(text, /"Obsidian Vault"/);
  assert.match(text, /obsidian:\/\/open\?vault=Obsidian%20Vault&file=1-Projects%2FExample%20Note\.md/);
  assert.equal(vaultLinkInstructions(""), "");
});
