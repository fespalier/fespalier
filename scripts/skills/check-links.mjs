#!/usr/bin/env node
// check-links — every relative link and every `#anchor` across the documentation.
//
// verify-coverage.mjs calls it (so `just skills` and CI's skills job run it), and it can be run alone:
//
//   node scripts/skills/check-links.mjs [path-to-fespalier-checkout]
//
// Files read: README.md, docs/*.md, skills/**/*.md, packages/*/README.md, examples/*/README.md,
// editors/*/README.md, AGENTS.md and ROADMAP.md. CHANGELOG.md is not (release-please writes it).
//
// What is checked:
//
//   - a relative link (`../examples/minimal`, `file-kinds.md#at-a-glance`) must name a file or a
//     directory that exists;
//   - a `#anchor` must be one of the target Markdown file's heading slugs (GitHub's rule: lower
//     case, backticks and punctuation dropped, spaces to `-`, `-1`, `-2` for a repeat) or a
//     `<a name="...">` / `<a id="...">` in it;
//   - an absolute link to this repository on GitHub, `https://github.com/fespalier/fespalier`
//     (`#anchor`, `/blob/main/<path>#anchor`, `/tree/main/<path>`), is read as the local file at
//     that path, so a link a package README sends over the web is checked too.
//
// Links inside fenced code blocks and inline code spans are examples, not links. Links to other
// sites are not this script's business.

import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, resolve, dirname, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_URL =
  /^https:\/\/github\.com\/fespalier\/fespalier(?:\/(blob|tree)\/main\/([^#]*))?(?:#(.*))?$/;

// GitHub's heading slug: lower case, no backticks, only letters, numbers, spaces, `-` and `_`,
// then each space is a `-`.
export function slug(heading) {
  return heading
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[*`]/g, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N} _-]/gu, "")
    .replace(/ /g, "-");
}

function withoutFences(text) {
  return text.replace(/^(```|~~~)[^\n]*\n[\s\S]*?^\1[^\n]*$/gm, "");
}

// Fenced blocks and inline code spans (a span becomes `x`, so a link's text survives).
function withoutCode(text) {
  return withoutFences(text).replace(/(`+)[^`]*?\1/g, "x");
}

const anchorCache = new Map();

// The anchors a Markdown file offers.
function anchorsOf(file) {
  if (anchorCache.has(file)) return anchorCache.get(file);
  const text = withoutFences(readFileSync(file, "utf8"));
  const seen = new Map();
  const set = new Set();
  for (const m of text.matchAll(/^#{1,6}[ \t]+(.+?)[ \t#]*$/gm)) {
    const base = slug(m[1]);
    const n = seen.get(base) ?? 0;
    seen.set(base, n + 1);
    set.add(n === 0 ? base : `${base}-${n}`);
  }
  for (const m of text.matchAll(/<a\s+[^>]*?\b(?:name|id)="([^"]+)"/g))
    set.add(m[1]);
  anchorCache.set(file, set);
  return set;
}

function markdownFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    if (
      [".git", "node_modules", "build", ".dart_tool", "target"].includes(e.name)
    )
      return [];
    const p = join(dir, e.name);
    if (e.isDirectory()) return markdownFiles(p);
    return e.name.endsWith(".md") ? [p] : [];
  });
}

export function documentationFiles(root) {
  const out = [];
  const add = (rel) => existsSync(join(root, rel)) && out.push(join(root, rel));
  add("README.md");
  add("AGENTS.md");
  add("ROADMAP.md");
  if (existsSync(join(root, "docs"))) {
    for (const f of readdirSync(join(root, "docs")).sort()) {
      if (f.endsWith(".md")) out.push(join(root, "docs", f));
    }
  }
  if (existsSync(join(root, "skills")))
    out.push(...markdownFiles(join(root, "skills")));
  for (const group of ["packages", "examples", "editors"]) {
    const dir = join(root, group);
    if (!existsSync(dir)) continue;
    for (const d of readdirSync(dir).sort()) {
      add(join(group, d, "README.md"));
    }
  }
  return out;
}

function linksOf(text) {
  const clean = withoutCode(text).replace(/<!--[\s\S]*?-->/g, "");
  const out = [];
  for (const m of clean.matchAll(/\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g))
    out.push(m[1]);
  for (const m of clean.matchAll(/^\[[^\]]+\]:\s*(\S+)/gm)) out.push(m[1]);
  for (const m of clean.matchAll(/<a\s+[^>]*?\bhref="([^"]+)"/g))
    out.push(m[1]);
  return out;
}

// Returns the list of problems, each a string naming the file and the link.
export function checkLinks(root) {
  const problems = [];
  let count = 0;
  for (const file of documentationFiles(root)) {
    const rel = relative(root, file).split(sep).join("/");
    const text = readFileSync(file, "utf8");
    for (const raw of linksOf(text)) {
      let targetFile;
      let anchor;
      const gh = REPO_URL.exec(raw);
      if (gh) {
        const path = gh[2] ?? "";
        targetFile = resolve(root, path || "README.md");
        anchor = gh[3];
        if (!path && anchor === "readme") anchor = undefined;
      } else if (/^[a-z][a-z0-9+.-]*:/i.test(raw) || raw.startsWith("//")) {
        continue; // another site, mailto:, ...
      } else {
        const [pathPart, ...rest] = raw.split("#");
        anchor = rest.length > 0 ? rest.join("#") : undefined;
        targetFile = pathPart
          ? resolve(dirname(file), decodeURI(pathPart))
          : file;
      }
      count++;
      if (!existsSync(targetFile)) {
        problems.push(`${rel}: ${raw} does not exist`);
        continue;
      }
      if (anchor === undefined || anchor === "") continue;
      let md = targetFile;
      if (statSync(md).isDirectory()) md = join(md, "README.md");
      if (!md.endsWith(".md") || !existsSync(md)) continue; // an anchor into code: not checked
      if (!anchorsOf(md).has(anchor)) {
        problems.push(
          `${rel}: ${raw}: no heading or <a name> "${anchor}" in ${relative(root, md).split(sep).join("/")}`,
        );
      }
    }
  }
  return { problems, count, files: documentationFiles(root).length };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = resolve(
    process.argv[2] ??
      join(dirname(fileURLToPath(import.meta.url)), "..", ".."),
  );
  const { problems, count, files } = checkLinks(root);
  if (problems.length > 0) {
    console.error(`check-links: ${problems.length} broken link(s)\n`);
    for (const p of problems) console.error(`  ✗ ${p}`);
    process.exit(1);
  }
  console.log(`check-links: ${count} links in ${files} files, none broken`);
}
