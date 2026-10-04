#!/usr/bin/env node
// verify-samples — compile the code samples of the skills.
//
// A code sample that does not compile is a claim that is false, and the one
// kind of false claim a reader copies without reading. This script builds the
// samples; CI does not run it (it builds a Flutter app per page, which is slow),
// so run it (`just skill-samples`) before opening a PR that touches a code
// block. See skills/CONTRIBUTING.md.
//
// How it works
//
//   - A fenced ```dart block whose FIRST line is `// lib/<path>` or
//     `// test/<path>` (nothing else on the line) is written to that path in a
//     scratch app. A ```yaml block whose first line is `# pubspec.yaml` is
//     appended to the scratch app's pubspec.yaml, and one whose first line is
//     `# pubspec.yaml dependencies` has its lines merged under `dependencies:`
//     (a recipe's plugin: firebase_auth, supabase_flutter, flutter_web_auth_2;
//     since 0.9.0). Every other block is a fragment and is not built.
//   - A page with a block that imports `package:fespalier_auth/`,
//     `package:fespalier_sign_keypair/`, `package:fespalier_adaptive/`, `package:fespalier_image/` or
//     `package:fespalier_sentry/` (since 0.9.0) gets that package as a path
//     dependency of this checkout, and a `dependency_overrides:` block pointing
//     `fespalier` and the companions at it: the companions pin fespalier by
//     repository tag, which a path dependency of the app cannot be resolved against.
//   - The scratch app is a copy of the fespalier checkout's `examples/minimal`
//     (the checkout is never modified): renamed `my_app` (the package name the
//     skills' imports use), depending on the checkout's packages/fespalier by
//     path, with its lib/app/ emptied and replaced by a root page and the root
//     transition.dart that `fsp init` writes.
//   - Each markdown file is built in a copy of that app, on its own: `fsp gen`,
//     `flutter analyze --no-fatal-infos`, and `flutter test` when the file
//     wrote anything under test/. Blocks of one file share one app, so within
//     a file two blocks for one path must be identical.
//
// Usage:  node scripts/skills/verify-samples.mjs [file.md ...]
//         FESPALIER_REPO=/path     another fespalier checkout (default: this one)
//         FSP=/path/to/fsp         the generator to use (default: `fsp` on PATH;
//                                  build one with `cd cli && cargo build`)
//         FLUTTER=/path/to/flutter the flutter tool (default: `flutter` on PATH)
//         KEEP=1                   keep the scratch apps (their paths are printed)
//
// Exit 0 = every sample built. Exit 1 = a sample failed. Exit 2 = bad setup.

import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
  appendFileSync,
} from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// The repository root, and skills/ inside it: the skills ship in the fespalier repository.
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SKILLS = join(ROOT, "skills");
// The fespalier to build against: this repository, unless FESPALIER_REPO names
// another checkout. Arguments are the markdown files to build (default: all).
const mdArgs = process.argv.slice(2);
const checkout = resolve(process.env.FESPALIER_REPO ?? ROOT);
const minimal = join(checkout, "examples", "minimal");
const pkg = join(checkout, "packages", "fespalier");
if (!existsSync(minimal) || !existsSync(join(pkg, "pubspec.yaml"))) {
  console.error(
    `verify-samples: ${checkout} has no examples/minimal or packages/fespalier ` +
      `(examples/minimal is the app the samples are built in).`,
  );
  process.exit(2);
}
const FSP = process.env.FSP ?? "fsp";
const FLUTTER = process.env.FLUTTER ?? "flutter";
const env = { ...process.env, CI: "true" };

const run = (cmd, args, cwd) =>
  spawnSync(cmd, args, { cwd, env, encoding: "utf8", maxBuffer: 1 << 28 });

for (const [what, cmd, args] of [
  ["fsp", FSP, ["--version"]],
  ["flutter", FLUTTER, ["--version"]],
]) {
  const r = run(cmd, args, ROOT);
  if (r.error || r.status !== 0) {
    console.error(`verify-samples: cannot run ${what} (${cmd}); set ${what.toUpperCase()}.`);
    process.exit(2);
  }
}

// ----------------------------------------------------------------- the base app

const scratch = mkdtempSync(join(tmpdir(), "fespalier-skills-samples-"));
const base = join(scratch, "base");
const skip = new Set(["build", ".dart_tool", "pubspec.lock", "README.md", "test"]);
cpSync(minimal, base, {
  recursive: true,
  filter: (src) => !skip.has(src.slice(minimal.length + 1).split("/")[0]),
});
rmSync(join(base, "lib", "app"), { recursive: true, force: true });
// app.main.g.dart is the example's generated main(): `fsp gen` writes a new one when a sample has a
// startup.dart, app.dart or splash.dart, and the old one would import files that are not there.
for (const f of ["app.g.dart", "app.main.g.dart", "items.dart"]) {
  rmSync(join(base, "lib", f), { force: true });
}

let pubspec = readFileSync(join(base, "pubspec.yaml"), "utf8")
  .replace(/^name: .*$/m, "name: my_app")
  .replace(/path: \.\.\/\.\.\/packages\/fespalier/, `path: ${pkg}`);
{
  // Drop the example's own `fespalier:` config (and the comments above it): the
  // samples run on the defaults.
  const lines = pubspec.split("\n");
  let at = lines.findIndex((l) => /^fespalier:/.test(l));
  if (at >= 0) {
    while (at > 0 && /^#/.test(lines[at - 1])) at--;
    pubspec = lines.slice(0, at).join("\n").trimEnd() + "\n";
  }
}
writeFileSync(join(base, "pubspec.yaml"), pubspec);

mkdirSync(join(base, "lib", "app"), { recursive: true });
writeFileSync(
  join(base, "lib", "main.dart"),
  `import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

void main() => runApp(
  ProviderScope(child: MaterialApp.router(routerConfig: AppRoutes.router())),
);
`,
);
writeFileSync(
  join(base, "lib", "app", "page.dart"),
  `import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => const Center(child: Text('Home'));
}
`,
);
writeFileSync(
  join(base, "lib", "app", "transition.dart"),
  `import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

Page<void> transition(LocalKey key, Widget child) =>
    Transitions.material(key, child);
`,
);
{
  const r = run(FLUTTER, ["pub", "get"], base);
  if (r.status !== 0) {
    console.error(`verify-samples: flutter pub get failed in the base app:\n${r.stdout}${r.stderr}`);
    process.exit(2);
  }
}

// ------------------------------------------------------------------- the files

const markdown = (dir) =>
  readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name);
    if (e.isDirectory()) return markdown(p);
    return e.name.endsWith(".md") ? [p] : [];
  });
const files = (mdArgs.length ? mdArgs.map((f) => resolve(f)) : markdown(SKILLS)).sort();

// The fenced blocks of a Markdown file: [{ lang, body }].
function blocks(text) {
  const out = [];
  const re = /^( *)```(\w*)[^\n]*\n([\s\S]*?)^\1```/gm;
  for (const m of text.matchAll(re)) {
    const indent = m[1];
    const body = indent
      ? m[3]
          .split("\n")
          .map((l) => (l.startsWith(indent) ? l.slice(indent.length) : l))
          .join("\n")
      : m[3];
    out.push({ lang: m[2], body });
  }
  return out;
}

let failed = 0;
let built = 0;
let skipped = 0;
for (const file of files) {
  const label = relative(ROOT, file);
  const written = new Map();
  const pubs = [];
  const deps = [];
  const problems = [];
  for (const { lang, body } of blocks(readFileSync(file, "utf8"))) {
    const first = body.split("\n", 1)[0].trim();
    if (lang === "dart" && /^\/\/ (lib|test)\//.test(first)) {
      const path = first.slice(3);
      if (/\s/.test(path)) {
        problems.push(`a block header must be only a path, got "${first}"`);
        continue;
      }
      if (written.has(path) && written.get(path) !== body) {
        problems.push(`two different blocks for ${path}`);
      }
      written.set(path, body);
    } else if ((lang === "yaml" || lang === "yml") && first === "# pubspec.yaml") {
      pubs.push(body.split("\n").slice(1).join("\n"));
    } else if (
      (lang === "yaml" || lang === "yml") &&
      first === "# pubspec.yaml dependencies"
    ) {
      // Lines for the `dependencies:` section (a recipe's plugin).
      deps.push(body.split("\n").slice(1).join("\n").trimEnd());
    }
  }
  if (written.size === 0 && pubs.length === 0 && deps.length === 0 && problems.length === 0) {
    skipped++;
    continue;
  }

  const app = join(scratch, `app-${built + failed}`);
  cpSync(base, app, { recursive: true, verbatimSymlinks: true });
  for (const [path, body] of written) {
    mkdirSync(dirname(join(app, path)), { recursive: true });
    writeFileSync(join(app, path), body);
  }
  // A page that imports the companion packages gets them as path dependencies of this checkout,
  // and `fespalier` overridden to the checkout's too: the companions pin it by repository tag,
  // which a path dependency of the app cannot be resolved against.
  const companions = [
    "fespalier_auth",
    "fespalier_sign_keypair",
    "fespalier_adaptive",
    "fespalier_image",
    "fespalier_sentry",
  ].filter((name) =>
    [...written.values()].some((body) => body.includes(`package:${name}/`)),
  );
  const depLines = [
    ...companions.map((name) => `  ${name}:\n    path: ${join(checkout, "packages", name)}`),
    // `# pubspec.yaml dependencies` blocks: indented under `dependencies:` as written.
    ...deps.flatMap((d) => d.split("\n")),
  ];
  if (depLines.length) {
    const path = join(app, "pubspec.yaml");
    const lines = readFileSync(path, "utf8").split("\n");
    const at = lines.findIndex((l) => /^dependencies:/.test(l));
    lines.splice(at + 1, 0, ...depLines);
    writeFileSync(path, lines.join("\n"));
  }
  if (pubs.length) appendFileSync(join(app, "pubspec.yaml"), "\n" + pubs.join("\n"));
  if (companions.length) {
    const overrides = ["dependency_overrides:", "  fespalier:", `    path: ${pkg}`];
    for (const name of companions) {
      overrides.push(`  ${name}:`, `    path: ${join(checkout, "packages", name)}`);
    }
    appendFileSync(join(app, "pubspec.yaml"), "\n" + overrides.join("\n") + "\n");
  }

  const steps = [];
  if (pubs.length || depLines.length) steps.push(["pub get", FLUTTER, ["pub", "get"]]);
  steps.push(["fsp gen", FSP, ["gen", "--project", app]]);
  steps.push(["flutter analyze", FLUTTER, ["analyze", "--no-fatal-infos"]]);
  if ([...written.keys()].some((p) => p.startsWith("test/"))) {
    steps.push(["flutter test", FLUTTER, ["test"]]);
  }
  let ok = problems.length === 0;
  const log = problems.map((p) => `  ✗ ${p}`);
  if (ok) {
    for (const [name, cmd, args] of steps) {
      const r = run(cmd, args, app);
      if (r.status !== 0) {
        ok = false;
        const tail = (r.stdout + r.stderr).split("\n").slice(-40);
        log.push(`  ✗ ${name} (exit ${r.status})\n${tail.map((l) => "      " + l).join("\n")}`);
        break;
      }
    }
  }
  if (ok) {
    built++;
    console.log(`✓ ${label} (${written.size} file${written.size === 1 ? "" : "s"})`);
  } else {
    failed++;
    console.log(`✗ ${label}\n${log.join("\n")}`);
  }
}

if (process.env.KEEP) console.log(`scratch apps kept in ${scratch}`);
else rmSync(scratch, { recursive: true, force: true });

console.log(
  `verify-samples: ${built} file(s) built, ${failed} failed, ${skipped} with no buildable block`,
);
process.exit(failed ? 1 : 0);
