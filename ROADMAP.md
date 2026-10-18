# Roadmap

What fespalier doesn't do yet, roughly in the order it is likely to land. Released features are
in CHANGELOG.md, and one-time maintainer steps (Homebrew tap, Scoop bucket, Marketplace) are in
docs/releasing.md, "Releasing". Ideas and bugs go in GitHub issues; an item here moves to the changelog when
it ships.

## Next

- **`fespalier_frb`, the rest.** The change feed ships in 0.13.0 (docs/data.md). Not built: a
  `flutter_rust_bridge` dependency (the generated bindings own it) and a rebuild budget for a core that
  emits thousands of events a second (coarser events or an `InvalidationTable` is the answer today).
- **A hot reload after a route is inserted.** `_dataN`/`_libN`/`_actionN_i` and their DevTools sites are
  numbered by position, so inserting a route before one refuses the swap and `fsp dev` restarts;
  folder-derived names would reload.
- **Editor support for tasks.** The VS Code and IntelliJ plugins list `fespalier: tasks:` as run
  configurations.
- **Make `Maestro flows open their routes on the web` a required check** once it has a few weeks
  of green runs.

## Later

- **Types resolved, not compared by spelling.** The generator reads a syntax tree, so a `typedef`
  and the type it names count as different types (see docs/troubleshooting.md, "Known limitations"). Resolving them needs the
  Dart analyzer, as a sidecar or through the analysis server.
- **Dashboards beyond the local stack.** The same dashboard spec rendered for hosted OpenObserve
  and Grafana Cloud.

## Waiting on others

- **`runGuarded` on the web.** `otel_zone`'s `runGuarded` never runs its body in a Flutter web app,
  so the docs use `kIsWeb ? body() : observability.runGuarded(body)` until it is fixed in
  vaam-apps/flutter-otel-zone.
- **OpenObserve:** a click on a stat tile opens nothing, and PromQL's `or vector(0)` returns no
  series (v1.0.4; v1.1.0 not checked yet). Drill-down is on the tables and charts until then, and the
  Grafana tiles work around the second.
