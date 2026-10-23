# Roadmap

What fespalier doesn't do yet, roughly in the order it is likely to land. Released features are
in CHANGELOG.md, and one-time maintainer steps (Homebrew tap, Scoop bucket, Marketplace) are in
docs/releasing.md, "Releasing". Ideas and bugs go in GitHub issues; an item here moves to the changelog when
it ships.

## Next

- **Make `Maestro flows open their routes on the web` a required check** once it has a few weeks
  of green runs.

## Later

- **Typedefs of other packages.** Since 0.21.0 `fsp` follows the typedefs and import prefixes of the app's own
  files (docs/troubleshooting.md, "Known limitations"); a typedef from another package is still compared as spelled.
  Reading `path:` dependencies the same way keeps the output a function of the files and the pubspec; a hosted package
  needs the Dart analyzer (a sidecar took 18-20 s per file without its cache when measured), so it could only add a
  hint, never change the output.
- **Dashboards beyond the local stack.** The same dashboard spec rendered for hosted OpenObserve
  and Grafana Cloud.

## Waiting on others

- **OpenObserve:** a click on a stat tile opens nothing (v1.0.4 to v1.1.2: the copy button's overlay over
  the value takes the click). Drill-down is on the tables and charts until then; Grafana's tiles open it.
