#!/usr/bin/env node
// verify-coverage — the parity gate between fespalier and its agent skills
// (skills/). CI runs it on every change (`just skills`), so a feature, a file
// kind, a config key or a command lands with the skill that teaches it.
//
// It fails in BOTH directions, deliberately:
//
//   docs -> skills   a fespalier feature that no skill claims fails the gate.
//                    That is the half that catches "a feature shipped and
//                    nobody taught the agents about it".
//
//   skills -> docs   an id claimed in coverage.json that does not exist in
//                    the fespalier checkout fails the gate. That is the half
//                    that catches a skill still describing something that
//                    moved, was renamed, or was deleted.
//
// A one-directional gate lets the map rot in the direction nobody looks.
//
// ---------------------------------------------------------------------------
// Adapted from vaam-apps/fyi-skills, vaam-apps/vpay-skills and
// vaam-apps/vsms-skills. What differs, and why — read this before "fixing" it
// back toward an exemplar.
// ---------------------------------------------------------------------------
//
// 1. THE SENTINEL. fespalier is a Rust CLI plus a Dart package in one
//    repository, so a checkout is recognised by `cli/Cargo.toml` naming the
//    `fespalier` crate AND `packages/fespalier/pubspec.yaml` existing. A bare
//    `AGENTS.md` identifies nothing.
//
// 2. THE DOCUMENTATION SURFACE IS NOT A PAGE TREE. fespalier has one long
//    README plus a few long pages under docs/ (docs/cratestack.md, docs/offline-first.md, docs/i18n-tolgee.md; docs/images holds README screenshots), so "one page per feature" does not exist.
//    What is machine-enumerable, and what a new feature has to touch, is:
//
//      README.md headings        every `##`..`####` outside a code fence is a
//                                section a skill must cover. Claimed as
//                                `README.md#<heading text>`.
//      file kinds                `Kind::file()` in cli/src/scan.rs: a new
//                                file name (`page.dart`, `route.dart`, ...)
//                                is a new thing an app can write. Claimed
//                                as `kind:<file name>`.
//      config keys               the fields of `RawConfig` in cli/src/config.rs
//                                (the `fespalier:` section of pubspec.yaml).
//                                Claimed as `config:<key>`.
//      commands                  the variants of `enum Cmd` in cli/src/main.rs.
//                                Claimed as `command:<name>`.
//      runtime library           every packages/fespalier/lib/**/*.dart and
//                                bin/*.dart file: one per runtime component.
//      generator source          every non-test cli/src/*.rs file: where the
//                                diagnostics live.
//      scaffold templates        every cli/templates/** file.
//      examples, editors         each directory under examples/ and editors/.
//      root documents            a fixed list (README.md, CHANGELOG.md, ...).
//
//    The kind, config and command surfaces are the load-bearing half, as
//    `crates/**/Cargo.toml` is in fyi-skills: a fifteenth file kind, an
//    eleventh config key or a seventh command fails the gate BY NAME until a
//    skill covers it. They are read from the Rust source with deliberately
//    narrow patterns; if fespalier restructures that code the gate says it
//    found nothing rather than passing.
//
// 3. `ancestors()` IS GENERALISED, AS IN fyi-skills. For the path surfaces a
//    claim on a directory STRICTLY BELOW the surface root covers the files
//    that existed there at the baseline commit; a bare surface root is not a
//    claim. The README-heading, kind, config and command ids have no
//    directory structure, so each must be claimed (or exempted) by itself.
//
// 4. INTERNAL LINKS ARE CHECKED HERE TOO. Nothing else in CI resolves a
//    relative link, so one from one skill page to another that moved would
//    otherwise ship. Every relative Markdown link under skills/ must resolve.
//
// 5. A STALE EXEMPTION IS A NOTE, NOT A FAILURE. An exemption is not a claim:
//    it asserts that nothing here describes the item, so one that points at
//    something absent exempts nothing and misleads no agent. (fyi-skills fails
//    it.) Here it matters because the baseline commit predates headings the
//    README has since gained, and the exemption list must pass on both.
//    A stale CLAIM is still a failure: that is a skill describing a thing that
//    is gone.
//
// Usage:  node scripts/skills/verify-coverage.mjs [path-to-fespalier-checkout]
//         (default: the repository this script is in)
//
// Exit 0 = parity. Exit 1 = a gap, named, with the file that closes it.
// Exit 2 = the path is not a fespalier checkout.

import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join, resolve, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

// The repository root, and skills/ inside it: the skills ship in the fespalier repository.
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SKILLS = join(ROOT, "skills");
const fespalier = resolve(
  process.argv[2] ?? process.env.FESPALIER_REPO ?? ROOT,
);

// See adaptation note 1.
const cargo = join(fespalier, "cli", "Cargo.toml");
if (
  !existsSync(cargo) ||
  !/^name\s*=\s*"fespalier"/m.test(readFileSync(cargo, "utf8")) ||
  !existsSync(join(fespalier, "packages", "fespalier", "pubspec.yaml"))
) {
  console.error(
    `verify-coverage: ${fespalier} does not look like a fespalier checkout ` +
      `(no cli/Cargo.toml naming the "fespalier" crate, or no ` +
      `packages/fespalier/pubspec.yaml).\n` +
      `Pass the path: node scripts/skills/verify-coverage.mjs /path/to/fespalier`,
  );
  process.exit(2);
}

const coverage = JSON.parse(readFileSync(join(SKILLS, "coverage.json"), "utf8"));
const failures = [];
const note = (s) => failures.push(s);

// A deliberately strict, dependency-free reader for the tiny subset of YAML a
// SKILL.md frontmatter is allowed to be: top-level `key: value` scalars only.
// It REJECTS what a real YAML parser rejects — chiefly an unquoted value
// containing ": ", which YAML reads as a nested mapping and which makes
// `npx skills add` skip the skill outright. Being stricter than the installer
// is safe; being looser is how a skill ships uninstallable and nothing says so.
function parseFrontmatter(text) {
  const value = {};
  for (const [i, raw] of text.split("\n").entries()) {
    if (!raw.trim() || raw.trimStart().startsWith("#")) continue;
    if (/^\s/.test(raw)) {
      return { error: `line ${i + 1}: unexpected indentation (nested YAML)` };
    }
    const m = /^([A-Za-z0-9_-]+):(.*)$/.exec(raw);
    if (!m) return { error: `line ${i + 1}: not a "key: value" pair` };
    const key = m[1];
    const v = m[2].trim();
    if (
      (v.startsWith('"') && v.endsWith('"') && v.length > 1) ||
      (v.startsWith("'") && v.endsWith("'") && v.length > 1)
    ) {
      value[key] = v.slice(1, -1).replace(/\\"/g, '"');
      continue;
    }
    if (v.includes(": ") || v.endsWith(":")) {
      return {
        error:
          `line ${i + 1}: "${key}" has an unquoted value containing ": ", ` +
          `which YAML reads as a nested mapping. Wrap the value in double quotes.`,
      };
    }
    if (/^[[{>|&*!%@`]/.test(v)) {
      return { error: `line ${i + 1}: "${key}" starts with a YAML indicator` };
    }
    value[key] = v;
  }
  return { value };
}

// ------------------------------------------------------------------- baseline
//
// A skill is true of *a* fespalier, not of fespalier. fespalier tags releases
// (v0.3.0), but a skill describes the TREE, and the tree moves between tags —
// so the honest version identity is a commit and a date, with the release it
// belongs to named beside it.
//
// This is REPORTED, never failed. Drift is the normal state between releases;
// what matters is that whoever reads the output knows it exists.

const baseline = coverage.baseline ?? {};
let drift = null;

const git = (...args) =>
  execFileSync("git", ["-C", fespalier, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }).trim();

if (baseline.fespalierRef) {
  try {
    const head = git("rev-parse", "HEAD");
    const headShort = head.slice(0, 8);
    const headDate = git("log", "-1", "--format=%cs", "HEAD");

    if (
      head.startsWith(baseline.fespalierRef) ||
      baseline.fespalierRef.startsWith(head)
    ) {
      drift =
        `baseline: fespalier ${headShort} (${headDate}) — exactly the tree ` +
        `these skills were verified against (${baseline.release ?? "untagged"})`;
    } else {
      let ahead = "?";
      let behind = "?";
      try {
        const counts = git(
          "rev-list",
          "--left-right",
          "--count",
          `${baseline.fespalierRef}...HEAD`,
        ).split(/\s+/);
        behind = counts[0];
        ahead = counts[1];
      } catch {
        // The baseline commit is not in this checkout at all — a shallow clone,
        // or a fork. Saying so is more useful than a wrong number.
        behind = ahead = "unknown (baseline commit not in this checkout)";
      }
      drift =
        `baseline: these skills were verified against fespalier ` +
        `${baseline.fespalierRef.slice(0, 8)} (${baseline.verifiedAt ?? "undated"}, ` +
        `${baseline.release ?? "untagged"}); this checkout is ${headShort} ` +
        `(${headDate}) — ${ahead} commit(s) newer, ${behind} commit(s) it does ` +
        `not have.\n            Version-sensitive claims carry the date they ` +
        `became true. See "Versions" in skills/README.md.`;
    }
  } catch {
    drift =
      `baseline: ${fespalier} is not a git checkout — cannot report drift from ` +
      `${baseline.fespalierRef.slice(0, 8)}`;
  }
} else {
  note(
    `coverage.json has no "baseline" block. Every published skill set names the ` +
      `fespalier commit it was verified against — see "Versions" in skills/README.md.`,
  );
}

// ---------------------------------------------------------------- skills side

const skillDirs = readdirSync(SKILLS).filter((d) =>
  statSync(join(SKILLS, d)).isDirectory(),
);

for (const dir of skillDirs) {
  const skillMd = join(SKILLS, dir, "SKILL.md");
  if (!existsSync(skillMd)) {
    note(`skills/${dir}/ has no SKILL.md`);
    continue;
  }
  const src = readFileSync(skillMd, "utf8");
  const fm = /^---\n([\s\S]*?)\n---/.exec(src);
  if (!fm) {
    note(`skills/${dir}/SKILL.md has no YAML frontmatter`);
    continue;
  }
  // Parse the frontmatter the way the INSTALLER does, not the way a regex
  // would. A gate that validates a different grammar from the consumer is not
  // a gate.
  const yaml = parseFrontmatter(fm[1]);
  if (yaml.error) {
    note(
      `skills/${dir}/SKILL.md frontmatter is not valid YAML: ${yaml.error}\n` +
        `      \`npx skills add\` runs a real YAML parser and SKIPS a skill it ` +
        `cannot parse, so this skill does not install at all. A description ` +
        `containing ": " must be quoted.`,
    );
    continue;
  }
  const { name, description } = yaml.value;

  if (name !== dir) {
    note(
      `skills/${dir}/SKILL.md declares name "${name}" — it must equal the ` +
        `directory name, because that is what \`--skill\` resolves.`,
    );
  }
  if (!description) {
    note(`skills/${dir}/SKILL.md has no description — it will never trigger.`);
  } else if (description.length < 80) {
    note(
      `skills/${dir}/SKILL.md description is ${description.length} chars. ` +
        `A description is the ONLY thing an agent reads when deciding whether ` +
        `to load the skill; say what it covers AND when to reach for it.`,
    );
  }

  if (!(dir in coverage.skills)) {
    note(`skills/${dir}/ has no entry in coverage.json`);
  }

  // The versioning rule (skills/README.md, "Versions"): every skill names the fespalier it was verified
  // against. Enforced rather than asked for, because the whole point is that
  // it must never be the line someone forgets.
  const stamp =
    /Verified against fespalier `([0-9a-f]{7,40})` \((\d{4}-\d{2}-\d{2})\)/.exec(
      src,
    );
  if (!stamp) {
    note(
      `skills/${dir}/SKILL.md carries no version stamp. Add, under the title:\n` +
        "        > **Verified against fespalier `<sha>` (<YYYY-MM-DD>), release <vX.Y.Z>.** …  — see skills/README.md, Versions",
    );
  } else if (baseline.fespalierRef && !baseline.fespalierRef.startsWith(stamp[1])) {
    // A stamp NEWER than the baseline is correct and expected: one skill
    // re-verified against a later fespalier without re-verifying the others.
    // Requiring every stamp to equal the baseline would make a one-skill
    // correction cost a full re-verification pass — which is how you get a
    // set of rubber-stamps. So the rule is "at least the baseline".
    let descendant = false;
    try {
      execFileSync(
        "git",
        [
          "-C",
          fespalier,
          "merge-base",
          "--is-ancestor",
          baseline.fespalierRef,
          stamp[1],
        ],
        { stdio: "ignore" },
      );
      descendant = true;
    } catch {
      descendant = false;
    }
    if (!descendant) {
      note(
        `skills/${dir}/SKILL.md is stamped fespalier ${stamp[1]}, which is not the ` +
          `baseline (${baseline.fespalierRef.slice(0, 8)}) and does not contain it. ` +
          `A stamp may be newer than the baseline — that is a skill re-verified ` +
          `on its own — but it may never be older or unrelated, because then the ` +
          `page makes claims about a tree nobody here has checked.`,
      );
    }
  }

  // Every references/*.md the SKILL.md points at must exist, and every file
  // under references/ must be reachable from SKILL.md. An unreferenced
  // reference page is a page no agent will ever open.
  const refDir = join(SKILLS, dir, "references");
  if (existsSync(refDir)) {
    const onDisk = readdirSync(refDir).filter((f) => f.endsWith(".md"));
    const linked = new Set(
      [...src.matchAll(/references\/([A-Za-z0-9._-]+\.md)/g)].map((m) => m[1]),
    );
    for (const f of onDisk) {
      if (!linked.has(f)) {
        note(`skills/${dir}/references/${f} is not linked from SKILL.md`);
      }
    }
    for (const f of linked) {
      if (!onDisk.includes(f)) {
        note(`skills/${dir}/SKILL.md links references/${f}, which is missing`);
      }
    }
  }
}

for (const skill of Object.keys(coverage.skills)) {
  if (!skillDirs.includes(skill)) {
    note(`coverage.json names skill "${skill}", which has no skills/ directory`);
  }
}

// ------------------------------------------- internal links must resolve
//
// Relative Markdown links only: `[x](references/y.md)`, `[x](../other/)` and
// reference-style `[x]: y.md`. http(s), mailto and bare `#anchors` are not this
// gate's business (sast.yml annotates dead URLs).

function markdownFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    if (e.name === ".git" || e.name === "node_modules") return [];
    const p = join(dir, e.name);
    if (e.isDirectory()) return markdownFiles(p);
    return e.name.endsWith(".md") ? [p] : [];
  });
}

let linkCount = 0;
for (const file of markdownFiles(SKILLS)) {
  // Links inside fenced code blocks are examples, not links.
  const text = readFileSync(file, "utf8").replace(/^```[\s\S]*?^```/gm, "");
  const targets = [
    ...[...text.matchAll(/\]\(([^)\s]+)\)/g)].map((m) => m[1]),
    ...[...text.matchAll(/^\[[^\]]+\]:\s*(\S+)/gm)].map((m) => m[1]),
  ];
  for (const raw of targets) {
    if (/^(https?:|mailto:|#)/.test(raw)) continue;
    const target = raw.split("#")[0];
    if (!target) continue;
    linkCount++;
    if (!existsSync(resolve(dirname(file), target))) {
      note(
        `${relative(ROOT, file)} links ${raw}, which does not exist. Fix the ` +
          `link, or the page it points at moved.`,
      );
    }
  }
}

// ------------------------------------------------ the fespalier-side surfaces

const read = (rel) => readFileSync(join(fespalier, rel), "utf8");

// Every directory and file below `dir`, as paths relative to the fespalier root.
const walk = (dir, prefix) =>
  readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory()
      ? walk(join(dir, e.name), `${prefix}/${e.name}`)
      : [`${prefix}/${e.name}`],
  );

// `## Heading` .. `#### Heading`, outside fenced code blocks, as `README.md#Heading`.
function readmeHeadings(text) {
  const out = [];
  let fenced = false;
  for (const line of text.split("\n")) {
    if (/^```/.test(line)) fenced = !fenced;
    const m = !fenced && /^#{2,4} (.+?)\s*$/.exec(line);
    if (m) out.push(`README.md#${m[1]}`);
  }
  return out;
}

// `Kind::Page => "page.dart"` inside `Kind::file()`. Narrow on purpose.
function fileKinds(text) {
  const body = /pub fn file\(self\)[\s\S]*?\n    \}\n/.exec(text)?.[0] ?? "";
  return [...body.matchAll(/Kind::\w+\s*=>\s*"([a-z_]+\.dart)"/g)].map(
    (m) => `kind:${m[1]}`,
  );
}

// The fields of `struct RawConfig { ... }`.
function configKeys(text) {
  const body = /struct RawConfig \{([\s\S]*?)\n\}/.exec(text)?.[1] ?? "";
  return [...body.matchAll(/^\s+([a-z_]+):\s*Option</gm)].map(
    (m) => `config:${m[1]}`,
  );
}

// The variants of `enum Cmd { ... }`, lower-cased as clap names them.
function commands(text) {
  const body = /enum Cmd \{([\s\S]*?)\n\}/.exec(text)?.[1] ?? "";
  return [...body.matchAll(/^    ([A-Z][A-Za-z]+)[\s({,]/gm)].map(
    (m) => `command:${m[1].toLowerCase()}`,
  );
}

const items = []; // { id, surface }
const rootOf = new Map(); // id -> the surface root a PATH item was found under
const add = (id, surface) => items.push({ id, surface });

const surfaces = [];

// The README's headings.
{
  const text = read("README.md");
  const ids = readmeHeadings(text);
  surfaces.push({ name: "README sections", count: ids.length });
  ids.forEach((id) => add(id, "README sections"));
}
// File kinds, config keys, commands: read from the Rust source.
for (const [name, file, parse] of [
  ["file kinds", "cli/src/scan.rs", fileKinds],
  ["config keys", "cli/src/config.rs", configKeys],
  ["commands", "cli/src/main.rs", commands],
]) {
  const ids = parse(read(file));
  if (ids.length === 0) {
    note(
      `found no ${name} in ${file}. Either fespalier restructured that code ` +
        `(update the pattern in scripts/skills/verify-coverage.mjs) or the checkout is wrong.`,
    );
  }
  surfaces.push({ name, count: ids.length });
  ids.forEach((id) => add(id, name));
}
// File-tree surfaces.
const pathSurfaces = [
  {
    name: "runtime library",
    root: "packages/fespalier/lib",
    match: (p) => p.endsWith(".dart"),
  },
  {
    name: "runtime launcher",
    root: "packages/fespalier/bin",
    match: (p) => p.endsWith(".dart"),
  },
  {
    name: "generator source",
    root: "cli/src",
    match: (p) =>
      p.endsWith(".rs") &&
      !/(_tests|^tests|^bench|^synth)\.rs$/.test(p.split("/").pop()) &&
      p.split("/").length === 3,
  },
  { name: "scaffold templates", root: "cli/templates", match: () => true },
];
for (const s of pathSurfaces) {
  const abs = join(fespalier, s.root);
  if (!existsSync(abs)) {
    note(
      `${fespalier}/${s.root} does not exist. This gate's fespalier -> skills ` +
        `direction has nothing to check under it — either fespalier reorganised ` +
        `(update scripts/skills/verify-coverage.mjs's surfaces) or the checkout is wrong.`,
    );
    continue;
  }
  const found = walk(abs, s.root).filter(s.match);
  surfaces.push({ name: s.name, count: found.length });
  for (const f of found) {
    add(f, s.name);
    rootOf.set(f, s.root);
  }
}
// One directory per example and per editor plugin.
for (const root of ["examples", "editors"]) {
  const abs = join(fespalier, root);
  if (!existsSync(abs)) {
    note(`${fespalier}/${root} does not exist.`);
    continue;
  }
  const dirs = readdirSync(abs)
    .filter((d) => statSync(join(abs, d)).isDirectory())
    .map((d) => `${root}/${d}`);
  surfaces.push({ name: root, count: dirs.length });
  dirs.forEach((d) => add(d, root));
}
// The documents that exist once, at known paths.
{
  const docs = [
    "README.md",
    "CHANGELOG.md",
    "ROADMAP.md",
    "install.sh",
    "install.ps1",
    "packages/fespalier/README.md",
    "packages/fespalier/CHANGELOG.md",
  ];
  const present = docs.filter((d) => {
    if (existsSync(join(fespalier, d))) return true;
    note(
      `${d} does not exist in ${fespalier}; update the root documents list in ` +
        `scripts/skills/verify-coverage.mjs if it moved.`,
    );
    return false;
  });
  surfaces.push({ name: "root documents", count: present.length });
  present.forEach((d) => add(d, "root documents"));
}

const claimed = new Set(
  Object.values(coverage.skills).flatMap((e) => e.covers ?? []),
);
const exempt = new Set(coverage.exempt ?? []);
const known = new Set(items.map((i) => i.id));

// Does a claimed id exist in the checkout? Paths by the filesystem; the rest by
// what the surfaces above just found.
const exists = (id) =>
  /^(README\.md#|kind:|config:|command:)/.test(id)
    ? known.has(id)
    : existsSync(join(fespalier, id));

for (const [skill, entry] of Object.entries(coverage.skills)) {
  for (const id of entry.covers ?? []) {
    if (!exists(id)) {
      note(
        `coverage.json: skill "${skill}" claims ${id}, which does not exist in ` +
          `${fespalier}. Either it moved or was renamed (update the claim AND the ` +
          `skill prose that cites it) or the feature was deleted (drop both).`,
      );
    }
  }
}

const existedAtBaseline = (path) => {
  if (!baseline.fespalierRef) return true; // no baseline: the gate already said so
  try {
    execFileSync(
      "git",
      ["-C", fespalier, "cat-file", "-e", `${baseline.fespalierRef}:${path}`],
      { stdio: "ignore" },
    );
    return true;
  } catch {
    return false; // absent at baseline, or the commit is not in this checkout
  }
};

// Ancestor directories of a PATH item, nearest first, stopping STRICTLY BELOW
// its surface root — so `cli/templates/new` is claimable but bare
// `cli/templates` is not. See adaptation note 3. A surface-root claim would
// make every file under it pass regardless of whether any skill's prose ever
// mentioned it.
function ancestors(id) {
  const root = rootOf.get(id);
  if (!root) return [];
  const rootDepth = root.split("/").length;
  const parts = id.split("/");
  const out = [];
  for (let end = parts.length - 1; end > rootDepth; end--) {
    out.push(parts.slice(0, end).join("/"));
  }
  return out;
}

// An item is covered when: its id is claimed, or it is exempted, or one of its
// ancestor directories is claimed AND it already existed at the baseline commit.
// That last clause is what makes a directory-level claim honest over time: the
// claim covers what was there when someone verified it, not whatever gets
// added afterward with nobody re-reading it.
function covers(id) {
  if (claimed.has(id) || exempt.has(id)) return true;
  for (const dir of ancestors(id)) {
    if (claimed.has(dir)) return existedAtBaseline(id);
  }
  return false;
}

const hint = {
  "README sections":
    "a README section: fold its content into the owning skill and claim it, or exempt it with a reason",
  "file kinds":
    "a new FILE KIND an app can write: it needs prose in `fespalier` (file-kinds.md) and in the skill that owns its behaviour",
  "config keys":
    "a new `fespalier:` config key: it needs prose in `fespalier` (cli-and-config.md) and in the skill that owns its behaviour",
  commands:
    "a new `fsp` command: it needs prose in `fespalier` (cli-and-config.md)",
};

for (const item of items) {
  if (!covers(item.id)) {
    const inherited = ancestors(item.id).some((d) => claimed.has(d));
    note(
      inherited
        ? `${item.id} was added to fespalier AFTER the baseline ` +
            `(${baseline.fespalierRefShort ?? baseline.fespalierRef?.slice(0, 8)}).\n` +
            `      Its directory is claimed, but that claim was earned against a ` +
            `tree that did not contain this file. Read it, fold it into the ` +
            `owning skill, and claim it explicitly — or exempt it with a reason.`
        : `${item.id} (${item.surface}) is not covered by any skill.\n` +
            `      This is ${hint[item.surface] ?? "a fespalier file a skill should account for"}.\n` +
            `      Add it to a skill's "covers" in coverage.json, and write the prose ` +
            `that earns the claim. If it genuinely needs no skill, list it under ` +
            `"exempt" with a reason in "exemptReasons".`,
    );
  }
}

const staleExempt = [];
for (const e of exempt) {
  if (!exists(e)) staleExempt.push(e);
  if (!coverage.exemptReasons?.[e]) {
    note(`coverage.json exempts ${e} with no reason in "exemptReasons"`);
  }
}

// ------------------------------------------------------------------ the report

if (failures.length > 0) {
  console.error(`\nverify-coverage: ${failures.length} gap(s)\n`);
  for (const f of failures) console.error(`  ✗ ${f}`);
  // Drift is printed on failure too, deliberately: "these skills are newer than
  // the tree you pointed me at" explains most of the gaps above when someone
  // runs this against an older fespalier.
  if (drift) console.error(`\n  ${drift}`);
  console.error(
    `\nThis gate is the docs↔skills parity rule. A fespalier feature that ships ` +
      `without a skill is a feature every agent will get wrong.\n`,
  );
  process.exit(1);
}

console.log(
  `verify-coverage: ${skillDirs.length} skills, ` +
    `${claimed.size} fespalier ids claimed, ` +
    `${items.length} items across ${surfaces.length} surfaces ` +
    `(${surfaces.map((s) => `${s.name} ${s.count}`).join(", ")}), ` +
    `${exempt.size} exempt, ${linkCount} internal links — parity against ${fespalier}`,
);
if (staleExempt.length > 0) {
  console.log(
    `            note: exempted but not present in this checkout (harmless): ` +
      staleExempt.join(", "),
  );
}
if (drift) console.log(`            ${drift}`);
