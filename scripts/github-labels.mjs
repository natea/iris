#!/usr/bin/env node
// Creates (or updates) the issue-tracker labels on the GitHub repo. The
// taxonomy is Conor Luddy's (conor.fyi/llm/github-labels-skill), verbatim, so
// his writing remains the documentation; AGENTS.md says how this repo uses it.
//
//   node scripts/github-labels.mjs            # natea/iris
//   node scripts/github-labels.mjs owner/repo
//
// Idempotent: `gh label create --force` updates an existing label in place, so
// running it twice is safe and a second run changes nothing.

import { execFileSync } from "node:child_process";

const repo = process.argv[2] || "natea/iris";

const groups = {
  Priority: [
    ["P1", "b60205", "Must ship first, blocks other work"],
    ["P2", "d93f0b", "Core features, ship after P1"],
    ["P3", "e99695", "Polish and low-urgency items"],
    ["P4", "f9d0c4", "Post-launch polish and enhancements"],
    ["P5", "fef2c0", "Nice to have, no pressure"],
  ],
  Clarity: [
    ["clarity:1", "5319e7", "Vague idea — no spec, no definition of done, needs discussion"],
    ["clarity:2", "7b61ff", "Problem defined, solution unclear — needs a design spike"],
    ["clarity:3", "a78bfa", "Direction known, details TBD — can start with questions"],
    ["clarity:4", "c4b5fd", "Clear spec, minor ambiguities — AI-shippable with light review"],
    ["clarity:5", "ddd6fe", "Crystal clear, full definition of done — just execute"],
  ],
  Risk: [
    ["risk:1", "0e8a16", "Isolated change, well-tested area, hard to break"],
    ["risk:2", "53d353", "Small surface area, existing patterns, minor regression chance"],
    ["risk:3", "fbca04", "Touches shared code, some edge cases, needs careful testing"],
    ["risk:4", "e99695", "Cross-domain impact, state management, concurrency concerns"],
    ["risk:5", "b60205", "Data model migration, navigation architecture, or seed data changes"],
  ],
  "Blast radius": [
    ["blast:1", "bfdadc", "Single file — one view or one service, no ripple effects"],
    ["blast:2", "7ec8cb", "Single domain — 2-5 files within one feature folder"],
    ["blast:3", "3bb3b8", "Cross-domain — touches shared code or 2+ feature domains"],
    ["blast:4", "1d7a7e", "Architectural — services, navigation, data flow changes"],
    ["blast:5", "0e4f52", "Full-stack — data pipeline + app, or schema changes"],
  ],
  Size: [
    ["size:XS", "c5def5", "Trivial change, single file"],
    ["size:S", "85c1e9", "Straightforward, few files"],
    ["size:M", "5dade2", "Moderate scope, some design needed"],
    ["size:L", "2e86c1", "Significant feature, many files"],
    ["size:XL", "1a5276", "Epic-level, major cross-cutting work"],
  ],
  Parallelism: [
    ["parallel:1", "f0e68c", "Lane 1 work stream"],
    ["parallel:2", "daa520", "Lane 2 work stream"],
    ["parallel:3", "cd853f", "Lane 3 work stream"],
    ["parallel:4", "b8860b", "Lane 4 work stream"],
    ["parallel:5", "8b6914", "Lane 5 work stream"],
    ["serial", "6c757d", "Cross-cutting — touches 2+ lanes, run alone"],
  ],
  Sequencing: Array.from({ length: 10 }, (_, i) => {
    const n = String(i + 1).padStart(2, "0");
    return [`seq:${n}`, "006b75", `Sequence step ${i + 1}`];
  }),
  Type: [
    ["type:bug", "d73a4a", "Something isn't working correctly"],
    ["type:feature", "0075ca", "New functionality or capability"],
    ["type:refactor", "cfd3d7", "Code improvement, no behaviour change"],
    ["type:chore", "ededed", "Maintenance — deps, CI, config, docs"],
    ["type:spike", "d4c5f9", "Research or time-boxed exploration"],
  ],
  Special: [
    // The label's own text sets the bar at risk 2; the essay says 3. The
    // label is what an agent reads, and the stricter bar is the safer default.
    ["ai-shippable", "1d76db", "Delegatable to AI agents — clarity:4+ and risk:2 or lower"],
    ["needs-design", "d4c5f9", "Requires design work before implementation"],
  ],
};

let count = 0;
for (const [group, labels] of Object.entries(groups)) {
  console.log(`\n${group}`);
  for (const [name, color, description] of labels) {
    execFileSync(
      "gh",
      ["label", "create", name, "--color", color, "--description", description, "--repo", repo, "--force"],
      { stdio: ["ignore", "ignore", "inherit"] },
    );
    console.log(`  ✓ ${name}`);
    count += 1;
  }
}
console.log(`\n${count} labels ensured on ${repo}`);
