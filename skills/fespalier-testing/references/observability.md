# Observability: dashboards on your computer with `fsp telemetry` (since 0.8.0)

fespalier reports spans for navigations, guards, `redirect.dart` files, `data.dart` loads, actions
and deferred loads (the telemetry conventions, contract v1). `fsp telemetry` starts the place to look
at them while you develop: a local OpenTelemetry collector, OpenObserve, and with `--grafana` Grafana,
with six ready-made dashboards. It is for development. Use it to see what a running app does, which
route is slow, which guard redirects, and which `data.dart` fails. It is not a test tool: a widget test
asserts behaviour (`pumpRouter`), and a production collector is the app's own.

The README section
[Dashboards on your computer](https://github.com/vaam-apps/fespalier#dashboards-on-your-computer-fsp-telemetry)
is the user documentation; the messages are in `fespalier-troubleshooting`,
`references/diagnostics-telemetry.md`.

## Start it

```sh
fsp telemetry             # writes ~/.fespalier/telemetry, runs `docker compose up -d`, imports the dashboards
fsp telemetry --grafana   # also Grafana at http://localhost:3000, with the same dashboards
flutter run               # any device
```

- It needs Docker with Compose 2.20 or later (`docker compose wait`) and a **running daemon**. It needs
  **no project**: run it in any folder. The stack is one per user: every app shares it, told apart by the
  dashboards' **App** variable (`service.name`).
- The first run pulls about 1.2 GB (1.9 GB with Grafana); later runs take seconds. Images are pinned by
  tag and digest, for `amd64` and `arm64`.
- It prints the addresses and the login (`dev@fespalier.local` / `Fespalier-local-1` by default).
  OpenObserve is at `http://localhost:5080`.
- Nothing is written into the app. The files are in `~/.fespalier/telemetry` (`--dir`,
  `FSP_TELEMETRY_DIR`); settings are in `.env` there, written once and never overwritten.
  `fsp telemetry --no-start --dir ops/telemetry` writes a copy to commit.

| Flag         | Does                                                                             |
| ------------ | -------------------------------------------------------------------------------- |
| `--grafana`  | Also starts Grafana                                                              |
| `--lan`      | Binds the OTLP ports to every interface for this run; writes `dart-defines.json` |
| `--stop`     | Stops the stack, keeps the data                                                  |
| `--reset`    | Stops it and deletes the data (the OpenObserve and Grafana volumes)              |
| `--dir <D>`  | Another folder than `~/.fespalier/telemetry`                                     |
| `--no-start` | Writes the files and prints `docker compose up -d`; runs no Docker               |

`--stop`, `--reset` and `--no-start` exclude the other flags (clap says `the argument '--stop'
cannot be used with '--grafana'`).

## Point the app at it

The app side is one value, the OTLP endpoint. `FespalierOtel.endpoint()` (in `package:fespalier_otel`)
picks it:

```dart
OtelZoneConfig(serviceName: 'shop', endpoint: FespalierOtel.endpoint())
```

It returns the `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=...` value when there is one; `''` in a release
build (so a store build never sends to a laptop); `http://10.0.2.2:4318` on Android (not the web); and
`http://localhost:4318` everywhere else.

| The app runs on                          | What to do                                                                                                 |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Android emulator, iOS simulator, desktop | Nothing                                                                                                    |
| Chrome (`flutter run -d chrome`)         | Nothing; the collector allows CORS from `http://localhost:*` and `http://127.0.0.1:*`                      |
| A phone on the same Wi-Fi                | `fsp telemetry --lan`, then `flutter run --dart-define-from-file=~/.fespalier/telemetry/dart-defines.json` |
| An Android phone on USB                  | `adb reverse tcp:4318 tcp:4318`, then `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`    |
| A changed `FSP_OTLP_HTTP_PORT`           | Pass the define; `endpoint()` always says 4318                                                             |

**On the web, do not run the app inside `otel_zone`'s `runGuarded`** (checked on `otel_zone` v0.5.0): it
opens a `ReceivePort` from `dart:isolate` before the body, the web has none, and the app stays blank with
nothing printed. `start()` works on the web. Use
`kIsWeb ? body() : observability.runGuarded(body)`. A page served over `https` cannot post to
`http://localhost`.

## Which dashboard answers what

All in OpenObserve's folder `fespalier` (and Grafana's). The default range is the last hour.

| Question                                                     | Dashboard                    | Panel                                        |
| ------------------------------------------------------------ | ---------------------------- | -------------------------------------------- |
| Which route is slow to its first frame?                      | `fespalier · Navigation`     | Time to first frame by route (p50, p95)      |
| Which navigations were redirected, and where did they land?  | Navigation                   | Redirected navigations, by where they landed |
| Is a route the app links to missing?                         | Navigation                   | Not found                                    |
| Which guard sends users away, throws, or keeps them waiting? | `fespalier · Guards`         | By guard; Async guard pending, p95           |
| Which `data.dart` fails or is slow?                          | `fespalier · Data`           | By data.dart; Load time, p95, by data.dart   |
| Do sync `data()` loads really stay sync?                     | Data                         | Sync and async loads                         |
| Which action fails, and how slow is it?                      | `fespalier · Actions`        | By action                                    |
| How long does a deferred page's code take?                   | `fespalier · Deferred loads` | By page                                      |
| What failed, where, with which message and trace?            | `fespalier · Errors`         | By error type; Recent failures (OpenObserve) |
| Did the app crash or hit an uncaught error?                  | Errors                       | Uncaught errors; Native crashes and ANRs     |

Panels for retries, cache hits, optimistic rollbacks and submits stopped by validation exist only when
the telemetry conventions emit those attributes (they are not in contract v1).

## OpenObserve and Grafana

- **Counts are the same** in both. **Percentiles differ**: Grafana's are interpolated within histogram
  buckets, OpenObserve's are exact. Grafana counts a span when the collector receives it, OpenObserve at
  the span's own time (a phone that replays a batch later differs).
- **Only OpenObserve has messages and trace ids** (_Recent failures_, _Recent uncaught errors_). Grafana
  reads span metrics through OpenObserve's PromQL API; there is no Tempo, Prometheus or Loki.
- **A dashboard edited in OpenObserve is left alone** when a new `fsp` carries a new version (the
  importer prints `changed in OpenObserve since fsp telemetry wrote it, left alone; delete it to get the
new version`). Delete it, run `fsp telemetry`, and it comes back. Grafana's are provisioned and
  read-only: save a copy to change one.
- The dashboards are **generated** from `scripts/telemetry/dashboards.toml` in the fespalier repository
  (`just telemetry-dashboards`); a fespalier contributor never edits the JSON.

## Traps

- **Empty dashboards** is almost always the app: telemetry not switched on or installed, a web app inside
  `runGuarded`, a phone without `--lan`, or a release build without the define. See the symptom table in
  `diagnostics-telemetry.md`.
- **The password is set on the first start.** A changed `FSP_O2_PASSWORD` needs `fsp telemetry --reset`
  (it deletes the data), and OpenObserve refuses a weak one.
- **Ports 3000 and 5080 are common.** Change `FSP_GRAFANA_PORT` / `FSP_O2_PORT` in `.env`.
- **`--lan` is for one run.** The next `fsp telemetry` binds to `127.0.0.1` again.

## The stack's files

`fsp` embeds `cli/templates/telemetry/` (`FILES` in `cli/src/telemetry_stack.rs`) and writes it, unchanged except
for `.env`, to the stack folder; the folder also runs as it is with `docker compose up -d`.

| File                                                         | What it is                                                                                                     |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `compose.yaml`, `env.example`                                | The four services (`collector`, `openobserve`, `dashboards`, `grafana` behind a profile) and `.env`'s defaults |
| `collector/config.yaml`                                      | OTLP in (with CORS), spans and logs out to OpenObserve, span metrics and error counts for Grafana              |
| `openobserve/import.py`                                      | The one-shot importer: waits, creates the streams' columns and the `fespalier` folder, loads the dashboards    |
| `openobserve/dashboards/*.json`, `grafana/dashboards/*.json` | The six dashboards, **generated** from `scripts/telemetry/dashboards.toml`                                     |
| `openobserve/fields.json`                                    | The columns the importer creates, **generated**                                                                |
| `grafana/provisioning/**`                                    | Grafana's data source (OpenObserve's PromQL API) and dashboard provider                                        |

Generated means `just telemetry-dashboards` writes them and `just telemetry` fails when they are stale;
never edit one by hand.
