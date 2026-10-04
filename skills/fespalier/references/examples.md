# The examples, and working in the repository

As of v0.4.0 (`examples/` in the fespalier repository). Read them before inventing a
pattern: they compile, have widget tests, and every `lib/app.g.dart` in them is committed.
A test in the repository fails if a committed `app.g.dart` is stale.

| Example              | What it is, and what to read it for                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `examples/minimal`   | The smallest real app: `flutter create` plus `fsp init` plus three pages (a class page, a function page `Widget page()`, and a `$id` page with a query parameter, a `data.dart`, `loading.dart` and `error.dart`). Its README walks through each file and how it was made. **Start here.** Added in 0.4.0                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `examples/shop`      | An end-to-end shop: products with `data.dart`, a `checkout` guard that sends an empty cart to `/cart`, `/greet/$name`, an `error.dart` with Retry (`/products/13` fails once), and, since 0.9.0, product photos through an image CDN (`fespalier_image`, an EmgR on `localhost:13001`, unsigned: a precache behind each row's `RouteLink` and an image hero), `/products/abc` going to `not_found.dart`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `examples/features`  | Almost every binding rule, with widget tests: an `(account)` group beside a catch-all `$slug`, per-route transitions, data keyed by two segments, query parameters in a page, `data.dart` and a layout, a user-written `AsyncNotifierProvider`, `Stream` data, a `teams/$teamId` **section** with a two-level `not_found.dart`, a query-keyed `reports` section, enum segments and catch-alls (`shop/$category`, `browse/$$categories`), typed catch-alls (`compare/$$ids`), `route.dart` case per folder (`files/`), **localized paths** (`help/`, `guide/` with non-ASCII spellings, `shop/`), guards in a page-less `(members)` group with a login that returns, two `redirect.dart` routes, dialogs, a sheet and a full-screen dialog under `/photos`, an app-owned sheet through `present.dart` (`/photos/share`), `meta.dart` read by the root layout for page titles, function views (`(plans)/free`, `(plans)/pro`), `extra` read by a layout and a guard, a `nest = false` sibling with a compound path (`orders/$id/refund/confirm`, beside `refund/receipt`, which nests), `action.dart` writes (a refund form on `orders/$id/refund`, an `addMember` on the `teams/$teamId` section), scroll restoration on the browser's back and forward (`feed/`, since 0.8.1), and `AppRoutes.dataAt`/`match`/prefetch tests |
| `examples/tabs`      | A tab layout: four tabs (one with nested pages, and a Library tab that is a tab layout of its own), a counter that survives switching tabs, `tabOptions`, a cross-fading `container`, a Search tab that also answers `/recherche`, a full-screen `/settings`, `/profile/edit` on the root navigator (`navigator.dart`), a Cupertino root `transition.dart` that also moves the shell aside, `extra_codec.dart`, an `output_manifest` library, restoration tests, and (since 0.9.0) a tab bar that is the menu: six `nav.dart` files drawn by `fespalier_adaptive` as a bar, a rail or a drawer by window width (a Library heading with Books and Authors, chips from an `AdaptiveNavBuilder`), with tests that resize the window                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `examples/auth`      | `fespalier_auth` (since 0.9.0): a sign-in form on an action (a wrong password is a `FieldErrors` under its field), `requireSignedIn`, `requireRole` and `redirectIfSignedIn` guards, orders pages whose two `data.dart` files share one token refresh through `authHttpClient`, `restoreAuth` in `startup()` (the first frame is the app), an in-process demo API (no network), and an `OidcBackend` against a Keycloak-shaped provider with a Keycloak 26.8.0 realm in `keycloak/`, and DPoP (`--dart-define=OIDC_ISSUER=demo --dart-define=DPOP=true`: tokens bound to a device key, a server that checks every proof). Read it with `fespalier-guards` (`references/auth-package.md`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `examples/telemetry` | The route lifecycle (`observe.dart`), OpenTelemetry through `otel_zone` and, since 0.9.0, errors in Sentry through `fespalier_sentry` (`SentryFlutter.init` in `main.dart`, both sinks in one `combine`, a `Refuse` button whose action throws, `RecordingSentry` in `test/sentry_test.dart`); on go_router 17                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |

Since 0.8.1 `minimal`, `shop` and `features` run the generated `main()` (`lib/main.dart` is
`Future<void> main() => AppMain.run();`, with `lib/app/app.dart`; `features` also has `startup.dart`,
`splash.dart` and a `zone()`, and tests them in `test/startup_test.dart`), and `tabs` keeps a `main()`
of its own. See [`app-main.md`](app-main.md).

Since 0.9.0 `features` also carries the state packages. **`/labs`** is behind a feature flag (`fespalier_flags`):
`lib/app/labs/guard.dart` is one `flagGuard(ref, labs, orElse: ...)`, `nav.dart` beside it is hidden while the flag is
off, `startup.dart` reads `--dart-define=FEATURES_LABS=true`, and `test/flags_test.dart` turns the flag on and off with a
`FakeFlags` while the menu is open and while the app is on `/labs`. Read it with `fespalier-guards`
(`references/feature-flags.md`).
**The team is kept in shared preferences** (`fespalier_storage`): `teams/$teamId/data.dart` has a `dataCache`, `startup.dart`
opens a `PrefsDataStorage`, and `test/offline_test.dart` restarts the app over the same in-memory store (`fakePrefsStore`):
the first frame of the second start is the saved team, a start that cannot load it shows the saved one, and `clear()` is a
sign-out. Read it with `fespalier-data` (`references/storage-backends.md`).
**The team loads again when the network comes back** (`fespalier_connectivity`): `teams/$teamId/route.dart` has
`refetchOnReconnect: true`, `startup.dart` overrides `reconnectSignal` with `ConnectivitySignal`, and `test/offline_test.dart`
flaps a `FakeConnectivity` (fresh within 30 seconds: nothing loads; Wi-Fi to mobile is not a reconnect; a network that flaps
loads once; a reload that fails keeps the page). Read it with `fespalier-data` (`references/reconnect-and-network.md`).

The examples nest `material_ui`'s `MaterialApp` around `MaterialApp.router` in their tests
so they pass on both go_router 17 and 18; with the root `transition.dart` that `fsp init`
writes you do not need that (`pumpRouter` uses Flutter's `MaterialApp`).

## Running one

```sh
cd examples/shop
flutter create . --platforms=android,ios,web   # adds platform folders only
flutter pub get
flutter run
```

## Working on fespalier itself

```text
cli/                 the generator (Rust): scan, resolve/check, emit
cli/templates/       minijinja templates for app.g.dart and `fsp new`
editors/vscode/      the VS Code extension (TypeScript)
editors/intellij/    the IntelliJ / Android Studio plugin (Kotlin)
scripts/             packaging and checksum pinning for releases
packages/fespalier/  the runtime app.g.dart imports, testing.dart, bin/fespalier.dart
examples/            minimal, shop, features, tabs
```

```sh
(cd cli && cargo test && cargo clippy --all-targets -- -D warnings)
(cd cli && cargo run -- check --project ../examples/minimal)
(cd packages/fespalier && flutter pub get && flutter analyze && flutter test)
(cd examples/minimal && flutter pub get && flutter analyze && dart format --set-exit-if-changed . && flutter test)
```

After changing the emitter or a template, regenerate the committed outputs with
`cargo run -- gen --project ../examples/<name>`. CI also checks that the version agrees
everywhere it is spelled out (`cli/tests/versions.rs`): `cli/Cargo.toml`, the package's
`pubspec.yaml`, the `ref:` that `fsp init` prints and the READMEs' `ref:`, `--tag` and
`FSP_VERSION`; **a release bumps those together**. The repository's `main` later moved to
release-please for that; follow whatever `README.md` "Releasing" says on the branch you are
on.

## Design notes worth knowing

- **`watch` and `read` are static** on a typed route, `prefetch` and `refresh` instance
  members: an instance member returning `AsyncValue<Product>` would make the generated file
  name `Product`, and it never copies your imports (`fespalier-data`).
- **A localized path is one `GoRoute` with an alternation**, not a redirect per spelling and
  not a route per spelling, so the URL, page keys, restoration ids and the tab stack see a
  single route (`fespalier-routing`).
- **The generated file never re-spells your types**, except a typed `extra` and enums, which
  it imports by name.
