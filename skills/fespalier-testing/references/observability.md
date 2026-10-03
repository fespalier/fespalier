# Observability: dashboards on your computer with `fsp telemetry` (since 0.8.0)

fespalier reports spans for navigations, guards, `redirect.dart` files, `data.dart` loads, actions
and deferred loads (the telemetry conventions, contract v1). `fsp telemetry` starts the place to look
at them while you develop: a local OpenTelemetry collector, OpenObserve, and with `--grafana` Grafana,
with four ready-made dashboards, written as the questions a developer asks ("Do screens open
quickly?"), not as metrics. It is for development. Use it to see what a running app does, which
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

| Flag         | Does                                                                                           |
| ------------ | ---------------------------------------------------------------------------------------------- |
| `--grafana`  | Also starts Grafana                                                                            |
| `--lan`      | Binds the OTLP ports to every interface for this run; writes `dart-defines.json`               |
| `--stop`     | Stops the stack, keeps the data                                                                |
| `--reset`    | Stops it and deletes the data (the OpenObserve and Grafana volumes)                            |
| `--report`   | Prints how each app is doing in plain words and exits (the stack must be running; since 0.8.0) |
| `--dir <D>`  | Another folder than `~/.fespalier/telemetry`                                                   |
| `--no-start` | Writes the files and prints `docker compose up -d`; runs no Docker                             |

`--stop`, `--reset`, `--no-start` and `--report` exclude the other flags (clap says `the argument
'--stop' cannot be used with '--grafana'`).

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

All in OpenObserve's folder `fespalier` (and Grafana's, where **App health** is the home page). The default
range is the last hour, and the **App** variable starts on the first app. Every title is a question, and the
ⓘ next to it (Grafana: (i)) says what the panel shows, what good looks like and which file to open.

| Question                                                     | Dashboard                | Panel                                                                   |
| ------------------------------------------------------------ | ------------------------ | ----------------------------------------------------------------------- |
| Is the app fast, and does it work?                           | `fespalier · App health` | Eight tiles; _Verdicts, in words_ (OpenObserve)                         |
| Do screens open quickly? Does content load quickly?          | App health               | _Do screens open quickly?_; _Does content load quickly?_                |
| Which screen is slow?                                        | `fespalier · Screens`    | _How long does each screen take?_; _Are screens getting slower?_        |
| Which `data.dart` fails or is slow?                          | Screens                  | _Which data.dart files are slow or failing?_                            |
| Which guard sends users away, throws, or keeps them waiting? | Screens                  | _Do checks slow screens down?_; _Where were people sent instead?_       |
| Is a route the app links to missing?                         | Screens                  | _How often does a link lead nowhere?_                                   |
| How long does a deferred page's code take?                   | Screens                  | _How long does a deferred page's code take to arrive?_                  |
| Which action fails, and how slow is it?                      | `fespalier · Actions`    | _Which actions are slow or failing?_                                    |
| What failed, where, with which message and trace?            | `fespalier · Errors`     | _What failed, and where?_; _What failed last?_ (OpenObserve)            |
| Did the app crash or hit an uncaught error?                  | Errors (and App health)  | _Did anything throw an uncaught error?_; _Did the app crash or freeze?_ |

Guards, `data.dart` and deferred pages are on **Screens**, not on dashboards of their own, because a developer
thinks "this screen is slow". Clicking a row of an OpenObserve table (a tile in Grafana) opens the dashboard that
explains it, with the App and the time range kept.

### What the colours mean (since 0.8.0)

A tile is green (good), amber (needs attention) or red (bad), by one table of limits for both backends and for the
dashed lines and table cells too. They are defaults for a mobile app; the README's "Reading the colours" has the
reason for each.

| Measure                                            | Good      | Needs attention | Bad       |
| -------------------------------------------------- | --------- | --------------- | --------- |
| Opening a screen (`screen_open`)                   | < 300 ms  | 300–999 ms      | ≥ 1000 ms |
| Loading a screen's content (`content_load`)        | < 1000 ms | 1000–2999 ms    | ≥ 3000 ms |
| Finishing an action (`action_time`)                | < 1000 ms | 1000–2999 ms    | ≥ 3000 ms |
| A check before a screen (`guard_wait`)             | < 100 ms  | 100–299 ms      | ≥ 300 ms  |
| A deferred page's code (`code_download`)           | < 500 ms  | 500–1999 ms     | ≥ 2000 ms |
| A load or action that fails (`failure_rate`)       | < 1 %     | 1–4.9 %         | ≥ 5 %     |
| A link that leads nowhere (`not_found_rate`)       | < 1 %     | 1–4.9 %         | ≥ 5 %     |
| Uncaught errors, failed operations (`error_count`) | 0         | 1–9             | ≥ 10      |
| Native crashes and freezes (`crash_count`)         | 0         | —               | ≥ 1       |

A tile that rests on **fewer than 20 samples is grey and says _Not enough data yet_** (the verdict table says _Too
few to judge_). Colour is not the only signal: OpenObserve's _Verdicts, in words_ says each answer as text.

Panels for retries, cache hits, optimistic rollbacks and submits stopped by validation exist only when
the telemetry conventions emit those attributes (they are not in contract v1).

## A summary without a browser: `--report` (since 0.8.0)

`fsp telemetry --report` prints, for each app that sent spans in the last hour, one line per App health question
(`✓ good`, `! needs attention`, `✗ bad`, `… too few to judge`, with the value), then the slowest screen, what fails
most (`Nothing failed.` when nothing did) and where the dashboard is. It runs `report.py` in the stack's own Python
container with App health's own SQL, so it needs the stack running and no Python on the host. An agent can read it
instead of opening a browser. Its messages are in `fespalier-troubleshooting`, `references/diagnostics-telemetry.md`.

## OpenObserve and Grafana

- **Counts are the same** in both. **Percentiles differ**: Grafana's are interpolated within histogram
  buckets, OpenObserve's are exact. Grafana counts a span when the collector receives it, OpenObserve at
  the span's own time (a phone that replays a batch later differs).
- **Only OpenObserve has messages and trace ids** (_What failed last?_, _What was uncaught last?_), and it alone has
  _Verdicts, in words_ and _Where do people go next?_. Grafana reads span metrics through OpenObserve's PromQL API;
  there is no Tempo, Prometheus or Loki, and it shows colour but no words.
- **A dashboard edited in OpenObserve is left alone** when a new `fsp` carries a new version (the
  importer prints `changed in OpenObserve since fsp telemetry wrote it, left alone; delete it to get the
new version`). Delete it, run `fsp telemetry`, and it comes back. Grafana's are provisioned and
  read-only: save a copy to change one. To change a colour limit, edit the dashboard in OpenObserve (it is then
  left alone). A dashboard a newer `fsp` no longer ships is deleted if nobody edited it.
- The dashboards are **generated** from `scripts/telemetry/dashboards.toml` in the fespalier repository
  (`just telemetry-dashboards`); a fespalier contributor never edits the JSON.

## Traps

- **Empty dashboards** is almost always the app: telemetry not switched on or installed, a web app inside
  `runGuarded`, a phone without `--lan`, or a release build without the define. See the symptom table in
  `diagnostics-telemetry.md`.
- **The password is set on the first start.** A changed `FSP_O2_PASSWORD` needs `fsp telemetry --reset`
  (it deletes the data), and OpenObserve refuses a weak one.
- **Grey tiles saying _Not enough data yet_** mean fewer than 20 samples, not a fault: use the app longer, or
  widen the time range.
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
| `openobserve/report.py`                                      | What `fsp telemetry --report` runs in the importer's container (since 0.8.0)                                   |
| `openobserve/dashboards/*.json`, `grafana/dashboards/*.json` | The four dashboards, **generated** from `scripts/telemetry/dashboards.toml`                                    |
| `openobserve/fields.json`                                    | The columns the importer creates, **generated**                                                                |
| `grafana/provisioning/**`                                    | Grafana's data source (OpenObserve's PromQL API) and dashboard provider                                        |

Generated means `just telemetry-dashboards` writes them and `just telemetry` fails when they are stale;
never edit one by hand.
