# Roadmap

What fespalier doesn't do yet, roughly in the order it is likely to land. Released features are
in CHANGELOG.md, and one-time maintainer steps (Homebrew tap, Scoop bucket, Marketplace) are in
docs/releasing.md, "Releasing". Ideas and bugs go in GitHub issues; an item here moves to the changelog when
it ships.

## Next

- **Editor support for tasks.** The VS Code and IntelliJ plugins list `fespalier: tasks:` as run
  configurations.

## Later

- **Dashboards beyond the local stack.** The same dashboard spec rendered for hosted OpenObserve
  and Grafana Cloud.

## Waiting on others

- **OpenObserve:** a click on a stat tile opens nothing (v1.0.4 to v1.1.2: the copy button's overlay over
  the value takes the click). Drill-down is on the tables and charts until then; Grafana's tiles open it.
