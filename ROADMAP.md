# Roadmap

What fespalier doesn't do yet, roughly in the order it is likely to land. Released features are
in CHANGELOG.md, and one-time maintainer steps (Homebrew tap, Scoop bucket, Marketplace) are in
README's "Releasing". Ideas and bugs go in GitHub issues; an item here moves to the changelog when
it ships.

## In progress (0.9.0)

- **`fsp dev`, `fsp build` and `fsp run`.** One command that runs `fsp watch` and `flutter run`
  together, with a terminal UI: a tab per process, the device and DevTools links, the route count,
  the last regeneration and the last hot reload. A regenerated `lib/app.g.dart` triggers a hot
  restart and other Dart saves a hot reload, through `flutter run --machine`, so it works on Windows
  too. Tasks live in `pubspec.yaml` under `fespalier: tasks:` (`run`, `before`, `with`, `after`,
  `env`), so codegen, `fvm` or a custom script fit in without a separate config file. Plain prefixed
  output in CI or with `--no-tui`.

## Next

- **Instrumentation the app doesn't have to write.** The generated `main()` already has hooks for
  this (`MainHooks` in `cli/src/entry.rs`) that nothing fills yet: with `telemetry: true` and an
  `app.dart`, `lib/app.main.g.dart` could install `FespalierOtel` and the zone itself, so
  `fsp telemetry` plus one pubspec line is the whole setup.
- **The four telemetry attributes that are documented as not emitted.** Forms (0.8) and data
  freshness (0.8) now have what they need: `fespalier.data.attempt` (retries),
  `fespalier.data.source` (cache or network), `fespalier.action.rolled_back` (an optimistic update
  undone) and `fespalier.action.invalid` (a form refused before it ran). Adding them is additive to
  contract v1, and brings back the retries, cache-hits and rollbacks panels in the dashboards.
- **Flutter 3.47.6.** A `build:` change on its own, because it needs `just devtools-build` and the
  committed DevTools extension build with it.
- **Editor support for tasks.** The VS Code and IntelliJ plugins list `fespalier: tasks:` as run
  configurations and show `fsp dev`'s diagnostics, from a machine-readable `fsp dev` event stream.
- **Make `Maestro flows open their routes on the web` a required check** once it has a few weeks
  of green runs.

## Later

- **Types resolved, not compared by spelling.** The generator reads a syntax tree, so a `typedef`
  and the type it names count as different types (see README's "Status"). Resolving them needs the
  Dart analyzer, as a sidecar or through the analysis server.
- **Dashboards beyond the local stack.** The same dashboard spec rendered for hosted OpenObserve
  and Grafana Cloud, with the import as a documented one-liner.

## Waiting on others

- **go_router 18 in `examples/telemetry`.** `otel_go_router` 0.2.0 still requires
  `go_router: ^17.0.0`; the fix is open upstream (Dartastic/otel_go_router PR #2). fespalier itself
  supports 17 and 18.
- **`runGuarded` on the web.** `otel_zone`'s `runGuarded` never runs its body in a Flutter web app,
  so the docs use `kIsWeb ? body() : observability.runGuarded(body)` until it is fixed in
  vaam-apps/flutter-otel-zone.
- **OpenTelemetry Collector 0.162.0.** Tagged, but no image is published yet; the stack stays on the
  pinned 0.161 image until one is.
- **OpenObserve:** a click on a stat tile opens nothing, and PromQL's `or vector(0)` returns no
  series (v1.0.4). Drill-down is on the tables and charts until then, and the Grafana tiles work
  around the second.
