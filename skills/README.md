# fespalier agent skills

Agent skills for fespalier: what an agent needs to write `lib/app/` correctly, and to
recover when `fsp` refuses it. They live here, next to the code they describe, and CI
checks them against that code on every change.

fespalier is the kind of project an agent gets confidently wrong. The router is
**generated**, so the code an agent reads (`lib/app.g.dart`) is the one thing it must
never edit. The rules are **in the file names and the constructors**, so a plausible
widget that breaks one of them fails in the generator, not in the compiler. Several
failures print **no message at all**: an optional `String? title` quietly becomes a
query parameter, a login page under its own guard ends on `Nothing at /login`, and
`fsp check` passes while the committed `app.g.dart` is stale.

**Not published yet.** Nothing installs these from a registry, and the commands below
point at a checkout of this repository.

## The skills

| Skill                                                     | Load it when                                                                                                   |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| [`fespalier`](fespalier/)                                 | Anything. Orientation, the file kinds, install, the golden rules, the map                                      |
| [`fespalier-routing`](fespalier-routing/)                 | Folders, segments, enums, typed routes, `route.dart` (incl. `nest`), `extra`, the manifest                     |
| [`fespalier-data`](fespalier-data/)                       | `data.dart`, loading and error views, retries, sections, prefetch, `dataAt`                                    |
| [`fespalier-layouts`](fespalier-layouts/)                 | `layout.dart`, tabs, transitions, dialogs, restoration, adaptive layouts                                       |
| [`fespalier-guards`](fespalier-guards/)                   | `guard.dart`, `redirect.dart`, `returnTo`, sign-in and refresh on auth change                                  |
| [`fespalier-testing`](fespalier-testing/)                 | `pumpRouter`, deep links, data states, and the traps that hang a test                                          |
| [`fespalier-observability`](fespalier-observability/)     | `observe.dart` hooks (analytics, titles), telemetry, OpenTelemetry with `otel_zone`, the telemetry conventions |
| [`fespalier-troubleshooting`](fespalier-troubleshooting/) | **An `fsp` error, a stale `app.g.dart`, a URL that shows the wrong page**                                      |
| [`fespalier-migration`](fespalier-migration/)             | Upgrading between releases, or adopting fespalier in a go_router app                                           |

Start with `fespalier`: it is the orientation skill and it routes to the rest. If
something is not working, read
[`fespalier-troubleshooting`](fespalier-troubleshooting/): it catalogues every `fsp`
diagnostic with its cause and fix.

## Using them

Each skill is a directory with a `SKILL.md`. An agent that reads skills from a folder
(Claude Code's `.claude/skills/`, or `.agents/skills/`) can use a copy or a link of the
directories you want:

```sh
# from an app, with a fespalier checkout next to it
mkdir -p .claude/skills
cp -r ../fespalier/skills/fespalier ../fespalier/skills/fespalier-routing .claude/skills/
```

Copy them from the tag your app pins (`ref:` in its `pubspec.yaml`), not from `main`,
if the two differ: a skill describes the code beside it.

## Versions

> **A skill is true of _a_ fespalier, not of fespalier.**

Every `SKILL.md` is stamped, under its title, with the commit it was last verified
against and the release that commit belongs to:

> **Verified against fespalier `122cb07f` (2026-10-01), release v0.4.0.**

- **The skills follow `main`.** A change to the generator, the runtime or the README
  updates the skills in the same pull request, and the coverage gate (below) fails it
  when a new README section, file kind, config key or command has no skill. A release
  tag therefore carries skills that describe that release.
- **The stamp moves when a skill is re-verified.** The gate refuses a stamp older than
  `baseline` in [`coverage.json`](coverage.json), or none; a newer stamp is a skill
  re-verified on its own. Re-verifying means checking each claim against the code and
  building its samples, not editing the stamp.
- **A version-sensitive claim names its release** ("since 0.4.0", "on 0.3.0 and
  earlier"), so a reader whose app pins an older fespalier can tell what applies.
- **The install pins** (`ref: v…`, `--tag v…`) in `fespalier/SKILL.md` and
  `fespalier-migration/references/go-router-adoption.md` are annotated for
  release-please, which moves them with every release, like the root README's.

## What is verified, and how

Every claim is checked against the source, not remembered: messages and flags against
`cli/src/*.rs` and `packages/fespalier/lib/`, and behaviour by running `fsp` and a
widget test.

- **The code samples compile.** A Dart block that starts with a `// lib/...` or
  `// test/...` comment is written into a scratch copy of `examples/minimal`, run
  through `fsp gen`, `flutter analyze` and, where it has tests, `flutter test`.
  `just skill-samples` does that for every page.
- **The diagnostics are real.** Each message in `fespalier-troubleshooting` was read
  from the generator's source or reproduced with `fsp check` on a tree that triggers it.
- **Where the README and the code disagree, the code wins**, the README is fixed, and
  [`known-wrong-docs.md`](fespalier-troubleshooting/references/known-wrong-docs.md)
  keeps the record for readers on older releases.

## The coverage gate

> **Every feature lands in three places or it has not landed: the code, the docs, and the
> skills.**

A skill that lags is worse than none: an agent does not merely trust it, it **acts** on
it. So CI runs a gate that fails in **both** directions (`just skills`, the job
"Skills match the code"):

```sh
node scripts/skills/verify-coverage.mjs
```

- **docs → skills.** A fespalier feature that no skill claims fails: a README section, a
  **file kind** (`Kind::file()` in `cli/src/scan.rs`), a `fespalier:` **config key**
  (`RawConfig` in `cli/src/config.rs`), an `fsp` **command** (`enum Cmd` in
  `cli/src/main.rs`), a runtime library file, a generator source file, a scaffold
  template, an example or editor directory, or a root document.
- **skills → docs.** An id claimed in [`coverage.json`](coverage.json) that no longer
  exists fails.

It also checks what an installer would: valid **frontmatter** (a description with an
unquoted `": "` is a nested YAML mapping, and an installer skips the skill), `name` equal
to the directory, a description of at least 80 characters, the version stamp, every
`references/*.md` linked from its `SKILL.md`, and every relative Markdown link.
`coverage.json` is the map: **the gate checks a claim exists; a reviewer checks it is
true.**

## Changing a skill

A skill is judged on **whether an agent that read it does the right thing**, not on
whether it is complete.

- **Prefer the caveat over the tour.** An agent can read the code. What it cannot recover
  from the code is the trap (an optional parameter that becomes a query parameter, a
  guard that covers its own login page). Those sentences are the product.
- **Check the code, not the README.** Open the `.rs` or `.dart` file, or better, run `fsp`
  on a tree that triggers it. If the README is wrong, fix it in the same change and add
  the item to `known-wrong-docs.md`.
- **Compile the samples.** Start a block with its path as a comment
  (`// lib/app/products/$id/page.dart`, `// test/products_test.dart`) and
  `just skill-samples` builds it; a block without one is a fragment, so keep fragments to
  one-liners that cannot be wrong in a way that matters.
- **Name what is not built** (no `refreshListenable` on `AppRoutes.router()`, no
  `--redirect` flag on `fsp new`). An agent will otherwise assume it exists.
- **Quote messages, don't paraphrase them**, so a search for the text finds the page; a
  message with backticks goes in a double-backtick span.
- **Correct, don't erase.** When a release changes a behaviour, say what it was and since
  when it isn't; the reader may be on the older release.

The shape:

```text
skills/<name>/
  SKILL.md              # frontmatter, the version stamp, then the prose
  references/*.md       # detail pages, each linked from SKILL.md
```

`name:` must equal the directory; `description:` is the only thing an agent reads when
deciding whether to load the skill, so say what it covers **and** when to reach for it.
Keep `SKILL.md` readable in one sitting and push detail into `references/`. Nine skills
is already a routing decision; fold new material into the owning skill rather than adding
one.

**A new file kind, config key, command or README section** fails the gate by name until a
skill claims it:

1. Read the code that implements it, and run `fsp` on a tree that uses it and one that
   misuses it.
2. Fold it into the owning skill, and into `fespalier`'s `references/file-kinds.md` or
   `cli-and-config.md` when it is one of those.
3. Add every diagnostic it can produce, with the exact message, to the matching page of
   `fespalier-troubleshooting`.
4. Add the id to that skill's `covers` in `coverage.json` (`kind:<file>`, `config:<key>`,
   `command:<name>`, `README.md#<heading>`, or the path).
5. `just skill-samples` for the pages you touched, then `just skills`.

Adding an id to `covers` without writing the prose passes the gate and defeats it.

The skills' Markdown and JSON are formatted with Prettier (`proseWrap: preserve`, see
[`.prettierrc.json`](.prettierrc.json)):

```sh
npx --yes prettier@3 --check "skills/**/*.{md,json}"
```

## Licence

MIT, as the rest of the repository.
