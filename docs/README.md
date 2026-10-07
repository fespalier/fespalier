# fespalier documentation

The [README](../README.md) is the 60-second path. These pages are the reference, one topic each.

| Page | What is in it |
| --- | --- |
| [Installation and setup](getting-started.md) | Every way to install `fsp`, the companion packages, `fsp init`, keeping `app.g.dart` in CI, platform notes |
| [Configuration](configuration.md) | Every key of the `fespalier:` section of `pubspec.yaml`, and `route.dart` |
| [File kinds](file-kinds.md) | What each file under `lib/app/` is, what it exports and what it receives |
| [Migration](migration.md) | Adopting fespalier in a go_router app, and what changed between releases |
| [Routing](routing.md) | Segment types, enums, catch-alls, query parameters, case, localized paths, groups, not-found views, the route manifest |
| [Navigation](navigation.md) | Typed navigation, `of` and `copyWith`, `remount`, `extra`, the root navigator, `RouteLink`, deferred routes |
| [Layouts](layouts.md) | Tab layouts, menus and breadcrumbs, adaptive navigation, transitions, state and scroll restoration |
| [Guards](guards.md) | `guard.dart`, `redirect.dart`, feature flags |
| [Data](data.md) | `data.dart`, retries, freshness, reconnects, caches, section data, typed helpers |
| [Actions and forms](actions.md) | `action.dart`, `form()` and `validate()`, optimistic updates |
| [HTTP clients](http.md) | Dio and `package:http`: cancelling, server field errors, writes never retried |
| [`main()`, app.dart, startup.dart and splash.dart](app-startup.md) | The generated `main()` and the three root files |
| [Adapters](adapters.md) | Packages that plug into the generated `main()` |
| [Authentication](auth.md) | Signed-in routes with `fespalier_auth`, OpenID Connect, device-bound tokens |
| [Images](responsive-images.md) | Responsive CDN images with `fespalier_image` |
| [Observability](observability.md) | Route lifecycle, telemetry, OpenTelemetry, Sentry, Crashlytics, conventions |
| [Dashboards on your computer](telemetry-dashboards.md) | `fsp telemetry`: OpenObserve and Grafana with fespalier's dashboards |
| [DevTools extension](devtools.md) | See routes, guards, data and actions in Flutter DevTools |
| [CLI reference](cli.md) | Every `fsp` command, the generated file, editor plugins, `fsp dev`, performance |
| [Testing](testing.md) | `pumpRouter`, `currentLocation`, the app around the router, deferred routes in tests |
| [Run the examples](examples.md) | minimal, shop, features, tabs, telemetry and auth |
| [Troubleshooting](troubleshooting.md) | Things to know, known limitations, symptoms |
| [FAQ](faq.md) | Design notes: why the API is shaped the way it is |
| [Development](development.md) | The repository layout, `just ci`, what CI runs |
| [Releasing](releasing.md) | How a release is cut (maintainers) |

This is where every section of the old single-file README went. An older link such as `github.com/fespalier/fespalier#telemetry`, or a message that says `(README, "Telemetry")`, finds its section here.

| Old README section | Now |
| --- | --- |
| Getting started | [README.md](../README.md#getting-started) |
| Running your app: `fsp dev` | [cli.md](cli.md#running-your-app-fsp-dev) |
| Tasks: commands around `flutter run` | [cli.md](cli.md#tasks-commands-around-flutter-run) |
| `fsp build` and `fsp run` | [cli.md](cli.md#fsp-build-and-fsp-run) |
| Plain output, CI and Windows | [cli.md](cli.md#plain-output-ci-and-windows) |
| File kinds | [file-kinds.md](file-kinds.md) |
| Function views | [file-kinds.md](file-kinds.md#function-views) |
| File names | [file-kinds.md](file-kinds.md#file-names) |
| How parameters are filled | [file-kinds.md](file-kinds.md#how-parameters-are-filled) |
| Segment types | [routing.md](routing.md#segment-types) |
| Enum segments | [routing.md](routing.md#enum-segments) |
| Catch-all segments | [routing.md](routing.md#catch-all-segments) |
| Typed catch-alls | [routing.md](routing.md#typed-catch-alls) |
| Case and trailing slashes | [routing.md](routing.md#case-and-trailing-slashes) |
| Localized paths | [routing.md](routing.md#localized-paths) |
| Non-ASCII spellings | [routing.md](routing.md#non-ascii-spellings) |
| `(group)` folders | [routing.md](routing.md#group-folders) |
| A sibling with a compound path | [routing.md](routing.md#a-sibling-with-a-compound-path) |
| Tab layouts | [layouts.md](layouts.md#tab-layouts) |
| Menus and breadcrumbs: `nav.dart` | [layouts.md](layouts.md#menus-and-breadcrumbs-navdart) |
| A bar, a rail or a drawer: fespalier_adaptive | [layouts.md](layouts.md#a-bar-a-rail-or-a-drawer-fespalier_adaptive) |
| Guards | [guards.md](guards.md) |
| `redirect.dart` | [guards.md](guards.md#redirectdart) |
| Sending people back | [guards.md](guards.md#sending-people-back) |
| Feature flags: fespalier_flags | [guards.md](guards.md#feature-flags-fespalier_flags) |
| Where flag values come from | [guards.md](guards.md#where-flag-values-come-from) |
| Testing flagged routes | [guards.md](guards.md#testing-flagged-routes) |
| Route lifecycle: `observe.dart` | [observability.md](observability.md#route-lifecycle-observedart) |
| Not-found views | [routing.md](routing.md#not-found-views) |
| Transitions | [layouts.md](layouts.md#transitions) |
| Shared elements (heroes) | [layouts.md](layouts.md#shared-elements-heroes) |
| The root navigator (`navigator.dart`) | [navigation.md](navigation.md#the-root-navigator-navigatordart) |
| `present.dart`: a page of your own | [navigation.md](navigation.md#presentdart-a-page-of-your-own) |
| Query parameters | [routing.md](routing.md#query-parameters) |
| The URL as state: `of` and `copyWith` | [navigation.md](navigation.md#the-url-as-state-of-and-copywith) |
| Remounting a page: `remount` | [navigation.md](navigation.md#remounting-a-page-remount) |
| Typed `extra` | [navigation.md](navigation.md#typed-extra) |
| Restoring `extra` on the web | [navigation.md](navigation.md#restoring-extra-on-the-web) |
| `data.dart`: a function, a selector or a provider | [data.md](data.md#datadart-a-function-a-selector-or-a-provider) |
| Retries and reloads | [data.md](data.md#retries-and-reloads) |
| Freshness: `staleTime`, resume and reconnect | [data.md](data.md#freshness-staletime-resume-and-reconnect) |
| Reconnects: fespalier_connectivity | [data.md](data.md#reconnects-fespalier_connectivity) |
| A cache that survives a restart: `dataCache` | [data.md](data.md#a-cache-that-survives-a-restart-datacache) |
| A cache on disk: fespalier_storage | [data.md](data.md#a-cache-on-disk-fespalier_storage) |
| Typed helpers on the route | [data.md](data.md#typed-helpers-on-the-route) |
| From a location to its data | [data.md](data.md#from-a-location-to-its-data) |
| Section data | [data.md](data.md#section-data) |
| `action.dart`: typed writes | [actions.md](actions.md#actiondart-typed-writes) |
| Forms: `form()` and `validate()` | [actions.md](actions.md#forms-form-and-validate) |
| Optimistic updates: `optimistic()` | [actions.md](actions.md#optimistic-updates-optimistic) |
| HTTP clients: fespalier_dio | [http.md](http.md) |
| Cancelling a load whose page is gone | [http.md](http.md#cancelling-a-load-whose-page-is-gone) |
| Server validation errors on forms | [http.md](http.md#server-validation-errors-on-forms) |
| Writes are never retried, over HTTP too | [http.md](http.md#writes-are-never-retried-over-http-too) |
| Links: `RouteLink` | [navigation.md](navigation.md#links-routelink) |
| Preloading the data behind a link | [navigation.md](navigation.md#preloading-the-data-behind-a-link) |
| Deferred routes: a page's code on demand | [navigation.md](navigation.md#deferred-routes-a-pages-code-on-demand) |
| Route manifest and `meta.dart` | [routing.md](routing.md#route-manifest-and-metadart) |
| State restoration | [layouts.md](layouts.md#state-restoration) |
| `main()`: app.dart, startup.dart and splash.dart | [app-startup.md](app-startup.md) |
| Adapters in the generated `main()` | [adapters.md](adapters.md) |
| Scroll restoration | [layouts.md](layouts.md#scroll-restoration) |
| The generator | [cli.md](cli.md#the-generator) |
| Deep links and a sitemap (`fsp links`) | [cli.md](cli.md#deep-links-and-a-sitemap-fsp-links) |
| Checking string paths | [cli.md](cli.md#checking-string-paths) |
| Maestro flows (`fsp maestro`) | [cli.md](cli.md#maestro-flows-fsp-maestro) |
| Web chunk sizes (`fsp size`) | [cli.md](cli.md#web-chunk-sizes-fsp-size) |
| Route smoke tests (`fsp test`) | [cli.md](cli.md#route-smoke-tests-fsp-test) |
| Performance | [cli.md](cli.md#performance) |
| Authentication | [auth.md](auth.md) |
| Installing fespalier_auth | [auth.md](auth.md#installing-fespalier_auth) |
| The session | [auth.md](auth.md#the-session) |
| Restoring at startup | [auth.md](auth.md#restoring-at-startup) |
| Guarding signed-in routes | [auth.md](auth.md#guarding-signed-in-routes) |
| Signing in and out | [auth.md](auth.md#signing-in-and-out) |
| Calling your API | [auth.md](auth.md#calling-your-api) |
| OpenID Connect and Keycloak | [auth.md](auth.md#openid-connect-and-keycloak) |
| Firebase, Supabase and your own API | [auth.md](auth.md#firebase-supabase-and-your-own-api) |
| Device-bound tokens: DPoP with fespalier_sign_keypair | [auth.md](auth.md#device-bound-tokens-dpop-with-fespalier_sign_keypair) |
| Testing signed-in routes | [auth.md](auth.md#testing-signed-in-routes) |
| Telemetry | [observability.md](observability.md#telemetry) |
| Turning it on | [observability.md](observability.md#turning-it-on) |
| OpenTelemetry with otel_zone | [observability.md](observability.md#opentelemetry-with-otel_zone) |
| Sentry: fespalier_sentry | [observability.md](observability.md#sentry-fespalier_sentry) |
| What Sentry gets from fespalier | [observability.md](observability.md#what-sentry-gets-from-fespalier) |
| Wiring Sentry | [observability.md](observability.md#wiring-sentry) |
| One transaction per screen | [observability.md](observability.md#one-transaction-per-screen) |
| Sentry defaults and privacy | [observability.md](observability.md#sentry-defaults-and-privacy) |
| Testing with Sentry | [observability.md](observability.md#testing-with-sentry) |
| Crashlytics | [observability.md](observability.md#crashlytics) |
| Several sinks: combine and add | [observability.md](observability.md#several-sinks-combine-and-add) |
| Spans around data() and actions | [observability.md](observability.md#spans-around-data-and-actions) |
| Where a navigation came from: navigateFrom | [observability.md](observability.md#where-a-navigation-came-from-navigatefrom) |
| Telemetry conventions | [observability.md](observability.md#telemetry-conventions) |
| Testing telemetry | [observability.md](observability.md#testing-telemetry) |
| What it costs | [observability.md](observability.md#what-it-costs) |
| Dashboards on your computer: `fsp telemetry` | [telemetry-dashboards.md](telemetry-dashboards.md) |
| The app side | [telemetry-dashboards.md](telemetry-dashboards.md#the-app-side) |
| The dashboards | [telemetry-dashboards.md](telemetry-dashboards.md#the-dashboards) |
| Reading the colours | [telemetry-dashboards.md](telemetry-dashboards.md#reading-the-colours) |
| The flags | [telemetry-dashboards.md](telemetry-dashboards.md#the-flags) |
| A summary in the terminal: `--report` | [telemetry-dashboards.md](telemetry-dashboards.md#a-summary-in-the-terminal---report) |
| The web and `otel_zone` | [telemetry-dashboards.md](telemetry-dashboards.md#the-web-and-otel_zone) |
| OpenObserve and Grafana show the same numbers | [telemetry-dashboards.md](telemetry-dashboards.md#openobserve-and-grafana-show-the-same-numbers) |
| Your own copy | [telemetry-dashboards.md](telemetry-dashboards.md#your-own-copy) |
| Images | [responsive-images.md](responsive-images.md) |
| Installing `fespalier_image` | [responsive-images.md](responsive-images.md#installing-fespalier_image) |
| The image CDN: `imageCdnProvider` | [responsive-images.md](responsive-images.md#the-image-cdn-imagecdnprovider) |
| Buckets: the widths an image is fetched at | [responsive-images.md](responsive-images.md#buckets-the-widths-an-image-is-fetched-at) |
| `ResponsiveImage` | [responsive-images.md](responsive-images.md#responsiveimage) |
| URL builders | [responsive-images.md](responsive-images.md#url-builders) |
| imgproxy and EmgR | [responsive-images.md](responsive-images.md#imgproxy-and-emgr) |
| Cloudinary | [responsive-images.md](responsive-images.md#cloudinary) |
| imgix | [responsive-images.md](responsive-images.md#imgix) |
| Thumbor | [responsive-images.md](responsive-images.md#thumbor) |
| A URL template | [responsive-images.md](responsive-images.md#a-url-template) |
| Already sized: a srcset | [responsive-images.md](responsive-images.md#already-sized-a-srcset) |
| Signed image URLs | [responsive-images.md](responsive-images.md#signed-image-urls) |
| Precaching an image behind a link | [responsive-images.md](responsive-images.md#precaching-an-image-behind-a-link) |
| Images in heroes | [responsive-images.md](responsive-images.md#images-in-heroes) |
| Images on the web | [responsive-images.md](responsive-images.md#images-on-the-web) |
| Caching images | [responsive-images.md](responsive-images.md#caching-images) |
| Testing images | [responsive-images.md](responsive-images.md#testing-images) |
| Image loads in telemetry | [responsive-images.md](responsive-images.md#image-loads-in-telemetry) |
| What images cost | [responsive-images.md](responsive-images.md#what-images-cost) |
| DevTools extension | [devtools.md](devtools.md) |
| Run the examples | [examples.md](examples.md) |
| Development | [development.md](development.md) |
| Releasing | [releasing.md](releasing.md) |
| Testing | [testing.md](testing.md) |
| Design notes | [faq.md](faq.md#design-notes) |
| Status | [troubleshooting.md](troubleshooting.md) |
| License | [README.md](../README.md#license) |
