# fespalier documentation

The [README](../README.md) is the 60-second path. These pages are the reference, one topic each.

| Page                                                               | What is in it                                                                                         |
| ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| [Installation and setup](getting-started.md)                       | Install options, companion packages, `fsp init`, CI, platform notes                                   |
| [Configuration](configuration.md)                                  | Every `fespalier:` key of `pubspec.yaml`, and `route.dart`                                            |
| [File kinds](file-kinds.md)                                        | What each file under `lib/app/` is, exports and receives                                              |
| [Migration](migration.md)                                          | Adopting fespalier in a go_router app, and what changed per release                                   |
| [Routing](routing.md)                                              | Segments, enums, catch-alls, query parameters, case, localized paths, groups, not-found, the manifest |
| [Navigation](navigation.md)                                        | Typed navigation, `of` and `copyWith`, `remount`, `extra`, `RouteLink`, deferred routes               |
| [Layouts](layouts.md)                                              | Tab layouts, menus, adaptive navigation, transitions, state and scroll restoration                    |
| [Guards](guards.md)                                                | `guard.dart`, `redirect.dart`, feature flags                                                          |
| [Data](data.md)                                                    | `data.dart`, retries, freshness, caches, section data, typed helpers                                  |
| [Actions](actions.md)                                              | `action.dart`, `validate()`, `FieldErrors`, optimistic updates                                        |
| [Forms](forms.md)                                                  | `form()` and `useForm` with `fespalier_forms`: typed fields, validation, server errors                |
| [HTTP clients](http.md)                                            | Dio and `package:http`: cancelling, field errors, writes never retried                                |
| [`main()`, app.dart, startup.dart and splash.dart](app-startup.md) | The generated `main()` and the root files                                                             |
| [Adapters](adapters.md)                                            | Packages that plug into the generated `main()`                                                        |
| [Authentication](auth.md)                                          | Signed-in routes with `fespalier_auth`, OpenID Connect, DPoP                                          |
| [Images](responsive-images.md)                                     | Responsive CDN images with `fespalier_image`                                                          |
| [Translations](i18n-tolgee.md)                                     | Tolgee texts with `fespalier_tolgee`: offline, over the air, language from the URL                    |
| [Maps](maps.md)                                                    | A pin picker that returns a place with `fespalier_maps`: MapLibre, geocoder, position                 |
| [Push notifications](push.md)                                      | Notification taps open typed routes with `fespalier_push`: cold start, warm taps, tokens              |
| [Observability](observability.md)                                  | Lifecycle hooks, telemetry, OpenTelemetry, Sentry, Crashlytics                                        |
| [Telemetry conventions](telemetry-conventions.md)                  | Span, event and attribute names: contract version 1                                                   |
| [Dashboards on your computer](telemetry-dashboards.md)             | `fsp telemetry`: OpenObserve and Grafana                                                              |
| [DevTools extension](devtools.md)                                  | Routes, guards, data and actions in Flutter DevTools                                                  |
| [CLI reference](cli.md)                                            | Every `fsp` command, the generated file, editor plugins, `fsp dev`, performance                       |
| [Route tests](route-tests.md)                                      | `fsp test` smoke tests and `fsp maestro` flows                                                        |
| [Testing](testing.md)                                              | `pumpRouter`, `currentLocation`, the app around the router                                            |
| [Run the examples](examples.md)                                    | minimal, shop, features, tabs, telemetry and auth                                                     |
| [Troubleshooting](troubleshooting.md)                              | Symptoms, things to know, known limitations                                                           |
| [FAQ](faq.md)                                                      | Why the API is shaped this way                                                                        |
| [Development](development.md)                                      | The repository, `just ci`, what CI runs                                                               |
| [Releasing](releasing.md)                                          | How a release is cut (maintainers)                                                                    |

## Old README sections

An older link such as `github.com/fespalier/fespalier#telemetry`, or a message that says `(README, "Telemetry")`, still works: the README keeps an anchor for every old heading, and each section now lives on the page below.

- [../README.md](../README.md): Getting started · License
- [cli.md](cli.md): Running your app: `fsp dev` · Tasks: commands around `flutter run` · `fsp build` and `fsp run` · Plain output, CI and Windows · The generator · Deep links and a sitemap (`fsp links`) · Checking string paths · Web chunk sizes (`fsp size`) · Performance
- [file-kinds.md](file-kinds.md): File kinds · Function views · File names · How parameters are filled
- [routing.md](routing.md): Segment types · Enum segments · Catch-all segments · Typed catch-alls · Case and trailing slashes · Localized paths · Non-ASCII spellings · `(group)` folders · A sibling with a compound path · Not-found views · Query parameters · Route manifest and `meta.dart`
- [layouts.md](layouts.md): Tab layouts · Menus and breadcrumbs: `nav.dart` · A bar, a rail or a drawer: fespalier_adaptive · Transitions · Shared elements (heroes) · State restoration · Scroll restoration
- [guards.md](guards.md): Guards · `redirect.dart` · Sending people back · Feature flags: fespalier_flags · Where flag values come from · Testing flagged routes
- [observability.md](observability.md): Route lifecycle: `observe.dart` · Telemetry · Turning it on · OpenTelemetry with otel_zone · Sentry: fespalier_sentry · What Sentry gets from fespalier · Wiring Sentry · One transaction per screen · Sentry defaults and privacy · Testing with Sentry · Crashlytics · Several sinks: combine and add · Spans around data() and actions · Where a navigation came from: navigateFrom · Operations of your own: TelemetryOp.custom · Testing telemetry · What it costs
- [navigation.md](navigation.md): The root navigator (`navigator.dart`) · `present.dart`: a page of your own · The URL as state: `of` and `copyWith` · Remounting a page: `remount` · Typed `extra` · Restoring `extra` on the web · Links: `RouteLink` · Preloading the data behind a link · Deferred routes: a page's code on demand
- [data.md](data.md): `data.dart`: a function, a selector or a provider · Retries and reloads · Freshness: `staleTime`, resume and reconnect · Reconnects: fespalier_connectivity · A cache that survives a restart: `dataCache` · A cache on disk: fespalier_storage · Typed helpers on the route · From a location to its data · Section data
- [actions.md](actions.md): `action.dart`: typed writes · `validate()` and `FieldErrors` · Optimistic updates: `optimistic()`
- [forms.md](forms.md): Forms: `form()` and `validate()` (form() since 0.11.0; validate() is in actions.md)
- [http.md](http.md): HTTP clients: fespalier_dio · Cancelling a load whose page is gone · Server validation errors on forms · Writes are never retried, over HTTP too
- [app-startup.md](app-startup.md): `main()`: app.dart, startup.dart and splash.dart
- [adapters.md](adapters.md): Adapters in the generated `main()`
- [push.md](push.md): Push notifications: fespalier_push · Install · Configure · Mapping a payload · Cold start and taps · Tokens and permission · Testing
- [route-tests.md](route-tests.md): Maestro flows (`fsp maestro`) · Route smoke tests (`fsp test`)
- [auth.md](auth.md): Authentication · Installing fespalier_auth · The session · Restoring at startup · Guarding signed-in routes · Signing in and out · Calling your API · OpenID Connect and Keycloak · Firebase, Supabase and your own API · Device-bound tokens: DPoP with fespalier_sign_keypair · Testing signed-in routes
- [telemetry-conventions.md](telemetry-conventions.md): Telemetry conventions
- [telemetry-dashboards.md](telemetry-dashboards.md): Dashboards on your computer: `fsp telemetry` · The app side · The dashboards · Reading the colours · The flags · A summary in the terminal: `--report` · The web and `otel_zone` · OpenObserve and Grafana show the same numbers · Your own copy
- [responsive-images.md](responsive-images.md): Images · Installing `fespalier_image` · The image CDN: `imageCdnProvider` · Buckets: the widths an image is fetched at · `ResponsiveImage` · URL builders · imgproxy and EmgR · Cloudinary · imgix · Thumbor · A URL template · Already sized: a srcset · Signed image URLs · Precaching an image behind a link · Images in heroes · Images on the web · Caching images · Testing images · Image loads in telemetry · What images cost
- [devtools.md](devtools.md): DevTools extension
- [examples.md](examples.md): Run the examples
- [development.md](development.md): Development
- [releasing.md](releasing.md): Releasing
- [testing.md](testing.md): Testing
- [faq.md](faq.md): Design notes
- [troubleshooting.md](troubleshooting.md): Status
