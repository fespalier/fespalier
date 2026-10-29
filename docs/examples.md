# Run the examples

Start with [`examples/minimal`](https://github.com/fespalier/fespalier/tree/main/examples/minimal), then read on for what each of the others shows. Each Flutter example's README also has screenshots of its web build, made by `just example-screenshots`.

Trees that `fsp` rejects are not examples: the smallest broken app folder for each of fifteen common diagnostics, with the output of `fsp check --json` beside it, is under [`cli/tests/fixtures/diagnostics/`](https://github.com/fespalier/fespalier/blob/main/cli/tests/fixtures/diagnostics/README.md). They are what the troubleshooting skill's messages are tested against.

## minimal

[`examples/minimal`](https://github.com/fespalier/fespalier/tree/main/examples/minimal) is the smallest app: `flutter create` + `fsp init` and three
pages (a class page, a function page and a `$id` page with a query parameter and a `data.dart`), with a
README that goes through each file and a few widget tests.

## shop

[`examples/shop`](https://github.com/fespalier/fespalier/tree/main/examples/shop) is a product list, a product page, a cart and a checkout behind a guard.

```sh
cd examples/shop
flutter create --empty . --platforms=android,ios,web   # adds the platform folders, .gitignore and .metadata
flutter pub get
flutter run
```

Every example's run steps use this command. The examples commit no platform folders, and a plain `flutter create` in an
existing app also writes a `test/widget_test.dart` for a `MyApp` that no example has, which fails `flutter analyze` and
`flutter test`: `--empty` leaves that test out. On a recent Flutter (checked with 3.47), every `flutter` command (`pub get`,
`run`, `test`, `build`) adds the platform folders to `analyzer: exclude:` in `analysis_options.yaml`. That is harmless;
`git checkout analysis_options.yaml` drops it when you are done.

Things to try:

- `/products/13` fails once, so you see `error.dart` and **Retry**.
- `/products/abc`: the int parse fails, so you get `not_found.dart`.
- `/checkout` with an empty cart: the guard redirects to `/cart`.
- `/greet/you`.
- `flutter test test/routes` runs [`fsp test`](route-tests.md#route-smoke-tests-fsp-test)'s smoke test of every route, with
  `test: a11y: true` (since 0.16.0): each also checks Flutter's tap-target, label and contrast guidelines on the whole screen.
  The app bar's title is a `TextButton` and its icon buttons have tooltips because those checks failed on them.

Since 0.9.0 the product photos come from an [EmgR](https://github.com/vaam-apps/image-resizer) on this
computer, unsigned. `examples/shop/lib/images.dart` says how to run it (`ALLOW_UNSIGNED_REQUESTS=true`,
and `ALLOWED_SOURCES` set to the photos' origin) and which `--dart-define`s point it elsewhere. Without
a server each photo fails and shows the product's initial.

- Hovering a row precaches the photo at the size its page shows
  ([Precaching an image behind a link](responsive-images.md#precaching-an-image-behind-a-link)).
- The photo flies to the page as an [image hero](responsive-images.md#images-in-heroes).
- Its tests use `FakeImages`.

## features

[`examples/features`](https://github.com/fespalier/fespalier/tree/main/examples/features) covers the rest. Routing and layouts:

- an `(account)` group next to a catch-all `$slug` page;
- per-route transitions (the group fades in, `/ticks` doesn't animate);
- data keyed by two segments;
- query parameters (in a page, `data.dart` and a layout);
- a page and error view bound by type;
- a layout and guard that take segments;
- a user-written `AsyncNotifierProvider`, and `Stream` data;
- a `teams/$teamId` section whose `data.dart` feeds its layout and pages, with a `not_found.dart` at two
  levels (which takes the team's id);
- a `reports` section keyed by a query parameter;
- enum segments, query parameters and catch-alls (`shop/$category`, `browse/$$categories`);
- `AppRoutes.dataAt` / `match` and the prefetch handle in `test/data_at_test.dart`;
- `orders/$id/refund/confirm`, a route that is a sibling of the `refund` page instead of a child of it
  (`nest = false`; `refund/receipt` next to it nests), with a guard on `refund/` that still guards it
  and widget tests for the stack a deep link builds.

**Writes.**

- `orders/$id/refund/action.dart` is a refund form. The page is a `HookConsumerWidget` on
  `RefundRoute.useAction`: a pending state, the error of a declined refund, and the quote beside it
  (`data.dart`) loads again after a success.
- `teams/$teamId/action.dart` adds a member to the section, whose data reloads for the layout and the
  page.
- `test/action_test.dart` holds a refund pending on a `Completer`, so nothing waits for time.

**Forms and optimistic updates** (since 0.8.1; forms are the `fespalier_forms` package since 0.11.0, which `examples/features` and `examples/auth` depend on).

- `(account)/nickname/` is a `HookConsumerWidget` on `NicknameRoute.useForm`: a `form()`, `validate()`
  and `optimistic()` beside its `action()`. It has errors per field, a save button that disables itself,
  a title that shows the new nickname at once and ends on the server's spelling, and fields that follow
  a reload unless the user changed them.
- `teams/$teamId/action.dart` has an `addMemberOptimistic()` that puts the member on the page before the
  section reloads.
- `test/forms_test.dart` and `test/teams_test.dart` hold the save pending on a `Completer`.

**Localized paths.**

- `help/` answers `/aide` and `/hilfe` too, with a dynamic child, a nested child that is localized
  itself, and a `not_found.dart` that covers every spelling.
- `guide/` has spellings beyond ASCII (`/führer`, `/руководство`).
- `shop/` is a page-less folder spelled `boutique` and `laden`, with an enum segment below it.

**Guards, redirects and overlays.**

- A guard in a page-less `(members)` group, with a login page that returns to where you were, and a
  second guard below it that runs after the first.
- Two `redirect.dart` routes (`/old-shops/:shop`, `/old-search`).
- `/photos`, with a dialog route (`/photos/:id`), a bottom sheet (`/photos/sort`), a full-screen dialog
  (`/photos/upload`) and an app-owned sheet with a URL (`/photos/share`, `present.dart`, with a page on
  top of it at `/photos/share/terms`) opening over it.
- Some routes have a `meta.dart` (`PageMeta`), which its root layout reads through the route manifest to
  set the page title; its tests join a review-code check on `AppRoutes.all`.
- It sets `scroll_restoration: true` (since 0.8.1): `/feed` has two lists under `PageStorageKey`s, and
  its tests play the browser's back and forward.
- It sets `links: domains` (since 0.16.0), so its `app.g.dart` has [`AppRoutes.urlOf`](cli.md#urls-to-share-approutesurlof);
  `test/url_of_test.dart` checks the canonical, `fr` and `fr-CA` spellings and a mount prefix.

**Feature flags** (since 0.9.0). `/labs` is a route behind a feature flag
([`fespalier_flags`](guards.md#feature-flags-fespalier_flags)): `lib/app/labs/guard.dart` is one
`flagGuard`, and the menu entry is hidden while the flag is off. It is off by default; run with
`--dart-define=FEATURES_LABS=true` to see it. `test/flags_test.dart` turns the flag on and off with a
`FakeFlags` while the menu is open and while the app is on `/labs`.

**A cache on disk** (since 0.9.0). The team is kept in shared preferences
([`fespalier_storage`](data.md#a-cache-on-disk-fespalier_storage)): `teams/$teamId/data.dart` has a
`dataCache`, `startup.dart` opens a `PrefsDataStorage`, and `test/offline_test.dart` restarts the app
over the same store. The first frame of the second start is the saved team, not `loading.dart`, and a
start that cannot load it shows the saved one.

**Reconnects** (since 0.9.0). The team also loads again when the device gets a network back
([`fespalier_connectivity`](data.md#reconnects-fespalier_connectivity)): `teams/$teamId/route.dart` has
`refetchOnReconnect: true`, `startup.dart` overrides `reconnectSignal`, and `test/offline_test.dart`
flaps a `FakeConnectivity`. Within the 30 seconds nothing loads, a Wi-Fi to mobile switch is not a
reconnect, and a network that flaps loads once.

## tabs

[`examples/tabs`](https://github.com/fespalier/fespalier/tree/main/examples/tabs) is a bottom navigation bar built as a tab layout:

- four tabs: one with nested pages, and a Library tab that is a tab layout of its own, with two inner
  tabs;
- a counter that survives switching tabs, `tabOptions`, and a cross-fading `container`;
- a Search tab that also answers `/recherche` (`route.dart` with `paths`);
- a full-screen route outside the tabs (`/settings`), and one that stays under `/profile` but renders on
  the root navigator (`/profile/edit`, `navigator.dart`);
- a Cupertino `transition.dart` that also moves the tab layout itself aside when one of those opens over
  it, and gives every route an opaque background (a Cupertino route paints a barrier under its page, which
  shows as grey through a page that is only a `Center`).

Since 0.9.0 its bar is the menu: six `nav.dart` files, drawn by
[`fespalier_adaptive`](layouts.md#a-bar-a-rail-or-a-drawer-fespalier_adaptive) as a bar, a rail or a
drawer by window width (the Library tab's two inner tabs are chips from an `AdaptiveNavBuilder`). Its
tests resize the window and check that a tab keeps its state.

It also keeps its manifest in a library of its own (`output_manifest: lib/app.routes.g.dart`, with
`Review` metas that `lib/main.dart` never imports). Its tests restore the selected tab, a background
tab's stack and a page's state after a simulated restart.

## telemetry

`examples/telemetry` (since 0.8.1) is the route lifecycle and OpenTelemetry:

- three tabs, an order page with a `data.dart`, an `action.dart` and an `observe.dart`, and a guarded
  and deferred settings page;
- `telemetry: true`, and a `main.dart` that wires `otel_zone` (`otel_zone` from the v0.8.1
  commit, so the example resolves go_router 18 like the others since 0.19.0);
- tests that read the hooks' log and the spans from an in-memory exporter.

Since 0.9.0 that `main.dart` also starts Sentry (`SENTRY_DSN` is empty, so nothing is sent), an order
page has a `Refuse` button whose action throws, and `test/sentry_test.dart` shows the event with its
route, its file and the OpenTelemetry trace of the same call.

## auth

`examples/auth` (since 0.9.0) is [`fespalier_auth`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_auth):

- a sign-in form on an action;
- a `requireSignedIn` guard that comes back to where the user was going, and a `requireRole` one for
  `/admin`;
- orders pages whose two `data.dart` files call an API through `authTransport` (`TransportClient(ref.watch(authTransport))`; an expired token is
  renewed once);
- a first frame that is the app, not a splash, because `startup()` restores the session with no network.

The API is an in-process server, so it runs and is tested with no network. To run against Keycloak, use the
`keycloak` profile, `fsp dev --profile keycloak -- -d chrome --web-port 8686` (since 0.24.0, [App configuration](app-config.md)),
and the realm in `examples/auth/keycloak/`. With `fsp dev --profile demo-dpop` it signs in against the demo
server's own provider with device-bound tokens (DPoP), and its tests check every proof the way a server does.

The device-sessions example, [`examples/device`](#device), is where the token-free scheme of `fespalier_sign_keypair` runs: enrolling a device, signed requests and renewal by re-attestation ([Device-signed sessions](auth.md#device-signed-sessions-fespalier_sign_keypair)).

## device

[`examples/device`](https://github.com/fespalier/fespalier/tree/main/examples/device) (since 0.21.0) is [`fespalier_sign_keypair`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_sign_keypair) end to end: a session with **no token** ([fespalier#267](https://github.com/fespalier/fespalier/issues/267), [Device-signed sessions](auth.md#device-signed-sessions-fespalier_sign_keypair)). Nothing stored works without the device's key, and no `Authorization` header is ever sent: every request carries `X-Attestation` and an `X-Signature` over its method, path, query and exact body bytes. Its [README](https://github.com/fespalier/fespalier/blob/main/examples/device/README.md) has a sequence diagram of an enrolment and a state diagram of the session.

- an enrolment page (`/enrol`): a phone number, then the one-time code (always `123456`), over a `DeviceAuthBackend` and a `DeviceAuthServer` of your own (`lib/device_server.dart`); a wrong number or code is the `FieldErrors` the server answered, under its field, and `redirectIfSignedIn` takes the user back to where they were going;
- a signed-in account: `requireSignedIn` means "this device is enrolled", and `/account` loads `GET /me` through `authTransport`, which renews the attestation once, silently, when it is within 12 hours of its end;
- a user-present action, `/transfer` (send money): its request asks for the user-present key through its attributes (`DeviceSigner.roleAttribute`), so the signature is made behind a biometric or the device credential, and a cancelled prompt fails that one request;
- a sign-out that revokes the device on the server, then deletes both keys; a key that was swapped or wiped is `SignedOut(keyLost)` at the next start;
- a demo server in pure Dart (`lib/demo/demo_api.dart`, in process, so the app runs with no network) that does what your server does: it issues an attestation per key, bound to it by `cnf.jkt`, and verifies **every** API request with `verifyDeviceSignature` and an in-memory set of `jti`s, so a signature is good once.

```sh
cd examples/device
flutter create --empty . --platforms=android,ios,web   # adds the platform folders, .gitignore and .metadata
flutter pub get
flutter run
```

Enrol with any phone number and the code `123456`. The keys are in the Secure Enclave or the AndroidKeyStore where the platform has them; the web has the ambient key only, so the transfer page says it cannot confirm.

Its tests run against the demo server, on a fake clock and `FakeKeypairSigner` keys: the enrolment and its field errors, every request verifying with no `Authorization` header and a signature accepted once, one renewal for two requests, a restore with no network (and `keyLost` after a key swap), the user-present prompt and its refusal, and the sign-out. **No test touches a secure element**: the real prompt, a device with no screen lock and biometric invalidation are unchecked on a device.

## plugins

[`examples/plugins`](https://github.com/fespalier/fespalier/tree/main/examples/plugins) (since 0.13.0) is the companion packages that plug in through `fespalier: adapters:`, starting with [`fespalier_push`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_push) and [`fespalier_analytics`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_analytics), and [`fespalier_launch`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_launch) (since 0.18.0) for home-screen shortcuts and widgets:

- `telemetry: true` and `adapters: [fespalier_push, fespalier_analytics, fespalier_launch]`; `main.dart` calls `FespalierPush.configure(...)`, `FespalierAnalytics.configure(...)` and `FespalierLaunch.configure(...)` (since 0.18.0) before `AppMain.run()`;
- a `FakePushSource` in place of Firebase Messaging, and debug buttons on the home page that simulate a tap on a notification, a `RecordingAnalytics` in place of the analytics SDK, and the consent buttons of a banner (`analyticsConsent`);
- an order page, a page behind a session guard and a login page that sends the person back;
- two `FakeLaunchSource`s, one for shortcuts and one for widget taps (since 0.18.0), and debug buttons on the home page that simulate a shortcut (`last_order`, order 42) and a widget tap (`plugins:///orders/7`, order 7), mapped by `launchRoute` in `lib/launch.dart`;
- tests through `AppMain.root()`: a cold start from a notification, a tap while the app runs, a guard on a tapped page, a foreign link refused, a tap delivered twice and the token and revocation callbacks, with `source=notification` read from `RecordingTelemetry`.
- launch tests through `AppMain.root()` (since 0.18.0, [Shortcuts and widgets](launch.md)): a cold start from a shortcut or a widget, a tap while the app runs and one while it starts, a signed-out shortcut to a guarded page, a URI and a shortcut the app does not map, and the two home-page buttons, with `source=shortcut` or `source=widget` read from `RecordingTelemetry`;
- analytics tests through `AppMain.root()` ([Analytics](analytics.md)): the first screen as a view named by `screenName`, nothing sent while undecided or after a refusal, a notification tap as a view with its source, a screen named `null` skipped, and no segment value in anything the backend is given.

## downloads

`examples/downloads` (since 0.15.0) is [`fespalier_download`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_download) with the foreground backend ([Downloads](downloads.md)), and the app a person tests downloads on a phone or a desktop with, no code to write:

- `adapters: [fespalier_download]`; `main.dart` calls `FespalierDownload.configure(...)` (through `configureDownloads()`) before `AppMain.run()`, with `HttpDownloadBackend`, `FileDownloadStore` and `TransferDownloadFiles`, a demo grantor and the mapping from a notification tap to a route;
- `/` is one card per case of the device test ([issue #157](https://github.com/fespalier/fespalier/issues/157)): a large file with a SHA-256, a small one, and a wrong checksum, each with the buttons that make sense for its `downloadStatus` (start, pause, resume, retry, cancel, remove), and a sign-out that calls `clearAccount()`;
- `/files/:id` is the detail page a notification tap opens: the status, the size and SHA-256 the file must have, the file and the partial file on disk, and where the finished file is;
- the files and digests are `--dart-define`s with public defaults (two Alpine Linux 3.22.0 files whose published SHA-256 was checked by downloading them);
- tests through `AppMain.root()` over `FakeDownloadBackend`, `MemoryDownloadStore` and `FakeDownloadFiles`: statuses from the backend, each button reaching the engine, a restart settled as `Failed (killed)`, sign-out, and a notification tap, cold and warm, opening the detail page.

```sh
cd examples/downloads
flutter create --empty . --platforms=android,ios,macos,linux,windows,web   # adds the platform folders, .gitignore and .metadata; keep the ones you test on
flutter pub get
flutter run -d <device id>
```

The [README](https://github.com/fespalier/fespalier/blob/main/examples/downloads/README.md) has the run steps for a tester, one per case, with what each must show and what to report; it needs no knowledge of fespalier.

## cose

[`examples/cose`](https://github.com/fespalier/fespalier/tree/main/examples/cose) is a full stack: a [`fespalier_cratestack`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_cratestack) app and the CrateStack server it talks to, in which every request is a **COSE_Sign1** message signed by a device key ([`fespalier_keypair`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_keypair)) and every answer is a COSE_Sign1 message signed by the server. The transport sends through the app's one [`HttpTransport`](http.md) (`TransportRequest` in, `TransportResponse` out; `startup()` builds it over `package:http`), so no `http.Client` is named outside `startup.dart`. Its [README](https://github.com/fespalier/fespalier/blob/main/examples/cose/README.md) has the design as built, a sequence diagram of a signed call, the life of the device key, and every status the server answers with.

- a `CoseTransport` that signs at send time, so an [intent](cratestack.md#5-actions)'s retries are new messages (a fresh `iat` and `cti`) over the same payload under the same `Idempotency-Key`, and a sealed answer that does not open is `CrateStackOffline` (the same key, never the next);
- a notes page whose read is `ref.serve` and whose write is an intent, with widget tests over `FakeCrateStackTransport`;
- a Dart COSE sealer and opener checked byte for byte against `cratestack-cose`'s own test vectors;
- a Rust server (`examples/cose/server`, no database, its own `Cargo.lock`) and an end-to-end test that starts its binary and drives the app's transport: registration, a signed write and read, and each refusal (unregistered key, tampered payload, plain CBOR, replay, a COSE body to the plain operation).

```sh
cd examples/cose/server && cargo run --locked -- --listen 127.0.0.1:8787   # prints the key to pin
cd examples/cose && flutter pub get && flutter test                         # the end-to-end test skips without COSE_SERVER_BIN
just cose                                                                   # the server's gates, then the app's with the server required
```

`HardwareKeypairSigner` (the hardware key) is not run by any test: they use a software key.

## cratestack

[`examples/cratestack`](https://github.com/fespalier/fespalier/tree/main/examples/cratestack) is the composition Webank runs: **a CrateStack backend, a client generated from its schema, and device-signed sessions** ([`fespalier_sign_keypair`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_sign_keypair), [Device-signed sessions](auth.md#device-signed-sessions-fespalier_sign_keypair)): no password, no token, no `Authorization` header. A small orders app, with a Rust server (`examples/cratestack/server`, no database, its own `Cargo.lock`) and the Flutter client that `cratestack generate-dart --preset fespalier` writes from its schema (`examples/cratestack/client`, committed, **no Dio**). Its [README](https://github.com/fespalier/fespalier/blob/main/examples/cratestack/README.md) has a sequence diagram of an enrolment and a signed call, a state diagram of the session, the decisions (RPC, how `fespalier_transport` is pinned, which generated files are committed), the gaps in the generated client and what the example does about each, and what is unchecked on a device.

- the app's **one transport**, built in `startup()`: `PortalTransport(WriteGuardTransport(HttpClientTransport(http.Client())))`, in the [order the transport page gives](transport.md#decorators-and-their-order). `AuthConfig(backend: DeviceAuthBackend(...), transport: <that chain>, apiOrigins: [server])` puts the session on top of it, and `ordersClientTransportProvider` (the generated client's seam, with `ordersClientBaseUriProvider`) is overridden with `ref.watch(authTransport)`: every generated call carries `X-Attestation` and `X-Signature` over its method, path, query and exact body bytes, and never `Authorization`;
- a `DeviceAuthServer` of your own whose four legs (begin and confirm an enrolment, begin and confirm a renewal) are public procedures of the schema, called through the **generated client over the plain chain** that has no session on it; the revocation is signed by hand with `signer.signFor`;
- an enrolment page (a phone number, then the code `123456`), `requireSignedIn` over the orders pages, a list read in [`ref.cancellable`](cratestack.md#4-reads-in-datadart) (leaving the page aborts the load) and served from the device when the server cannot be reached, a detail page, and a write with an `Idempotency-Key` whose validation answer is `FieldErrors` under its field;
- a sensitive call, `payOrder`, that asks for the **user-present key**: a generated call has no attributes for the signer, so it sets a header that `ConfirmTransport` (above the session) turns into `DeviceSigner.roleAttribute`; a cancelled prompt fails that call only; sign-out revokes the device, then deletes both keys;
- a server whose layer in front of the generated router reads the body, verifies the attestation (the issuer's signature, `cnf.jkt`, the expiry) and the signature (`mth`, `pth`, `qsh`, `bdh`, `aud`, freshness, a single-use `jti`) and answers a refusal with the code the client's classifier reads (`401 attestation_expired`, `403 DEVICE_REVOKED`, ...); CrateStack's `AuthProvider` then only turns the verified device into the caller its policies see.

```sh
cd examples/cratestack/server && cargo run --locked -- --listen 127.0.0.1:8788   # the server
cd examples/cratestack && flutter pub get && flutter test                          # the end-to-end test skips without ORDERS_SERVER_BIN
just cratestack-cli && just cratestack                                              # the server's gates, the client compared with a fresh one, then the app's with the server required
```

Its tests run on an in-memory server over `FakeTransport` (enrolment, signed calls, an abort on leaving a page, offline, one renewal for an expired attestation, the user-present rule, sign-out), and **`test/e2e_test.dart` starts the real Rust binary**: Dart's signatures are verified by a verifier written from the profile and not from Dart's code. `HardwareKeypairSigner` and the user-present prompt are not run by any test: they use fake keys.

## wire-sizes

[`examples/wire-sizes`](https://github.com/fespalier/fespalier/tree/main/examples/wire-sizes) is a **measurement**, not an app: one CrateStack schema served as JSON, plain CBOR and `COSE_Sign1` CBOR, with every call weighed by a layer in the server that handles it: the request line, headers and body of each request and the status line, headers and body of each response, as the server's handler stack sees them. That is a count of the HTTP message, not a capture of a socket: `host`, `content-length`, hyper's `date` and TCP/TLS framing are not in it, so totals are lower bounds. It answers the question [`examples/cose`](https://github.com/fespalier/fespalier/tree/main/examples/cose) raises: what does signing a call actually cost?

- a Rust server (`examples/wire-sizes/server`, no database, its own `Cargo.lock`) whose `--variant json|cbor|cose` picks the codec, and whose outermost middleware records each exchange before any inner layer can refuse it;
- a runner that drives the same scenario through all three variants **in process** (`tower`'s `oneshot`, no socket), so it can read the server's own log back; `tests/socket.rs` sends the same requests over a real socket and pins what that adds;
- an attributed `cose` overhead: the payload, the protected header, the 64-byte signature and the external AAD are separated, so the delta is explained rather than reported;
- a **generated** `REPORT.md`, with a test that fails when the committed report is stale.

```sh
cd examples/wire-sizes/server && cargo run --locked -- --variant cbor --listen 127.0.0.1:8787
cd examples/wire-sizes/server && cargo run --locked --quiet --bin wire-sizes-report    # the tables
just wire-sizes                                                                        # fmt, clippy, tests, deny, and the report compared with REPORT.md
```

The scenario's payloads are tens of bytes, so its totals are mostly headers; the sweeps go to 300 KB, where JSON's overhead over CBOR depends on whether the text needs escaping. The `Bearer` baseline is realistic in _size_ but not verified, which the report says.

## frb-cose

[`examples/frb-cose`](https://github.com/fespalier/fespalier/tree/main/examples/frb-cose) (since 0.21.1) is the notes app of [`examples/cose`](https://github.com/fespalier/fespalier/tree/main/examples/cose) with a different split: the network layer is a **Rust core** behind [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) 2.13.0, and the core is CrateStack's own generated Rust client. It seals every call as a `COSE_Sign1` message with `cratestack-cose`, and the device key (a `KeypairSigner` from [`fespalier_keypair`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_keypair), as in `examples/cose`) stays in Dart, which the core calls back to sign. Its [README](https://github.com/fespalier/fespalier/blob/main/examples/frb-cose/README.md) has the architecture, a sealed call across the bridge, the answer table and the parts that are not built.

- the core (`rust/`) is `include_client_schema!` over the example's own schema, on `cratestack-client` 0.15.3 with its `cose` feature: the sealed transport, the registration of the device key and the journal of the calls are CrateStack's, or the core's on top of them, never re-implemented in Dart;
- a `CoreTransport` implements `CrateStackTransport` over the core, so [`fespalier_cratestack`](cratestack.md)'s `ref.serve` (the read) and its intents (the write, under one `Idempotency-Key`) run unchanged;
- the core's events (`Registered`, `Forgotten`, `Called`) are one subscription in a [`ChangeFeed`](streaming.md#something-changed-changefeed), and the `/core` page rebuilds on each one;
- a Rust server (`examples/frb-cose/server`, a copy of the cose server, in memory) and the tests: the core in Rust against the server in process, the Dart tests against the real core built by the build hook, and an end-to-end test that starts the server's binary.

```sh
cd examples/frb-cose/server && cargo run --locked -- --listen 127.0.0.1:8787 --server-scalar-hex <64 hex digits>   # prints the key to pin
cd examples/frb-cose && flutter create --empty . --platforms=android,ios,macos,linux,windows   # adds the platform folders
flutter run --dart-define=FRB_COSE_SERVER_JWK='{…}' --dart-define=FRB_COSE_SERVER_URL=http://127.0.0.1:8787
cd examples/frb-cose && flutter test   # builds the Rust core first: rustup is needed, and the first run installs the targets rust/rust-toolchain.toml lists (about 2 GB, once)
just frb-cose                          # the server's and the core's gates, the bindings check, then the app's tests with the server required
```

The server keeps its notes and registrations in memory, and a restart forgets them. So does the app: its read copy and its queued writes are in the package's default `InMemoryLocalStore`, so an app restart drops them (a durable `HiveLocalStore` from `fespalier_cratestack/hive.dart` is how an app keeps them; the example does not wire it). A web build has no core: its pages say so and make no call. The steps a device needs (the native build on each platform, the device key's callback into a hardware keystore, plain `http` from the core's socket on Android and iOS, and backgrounding during a call) are not checked by any test; the README lists them as UNCHECKED, and the device-test issue, [fespalier/fespalier#271](https://github.com/fespalier/fespalier/issues/271), has the steps to try them.

## i18n

[`examples/i18n`](https://github.com/fespalier/fespalier/tree/main/examples/i18n) is [`fespalier_tolgee`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_tolgee) with no network and no key (see [i18n with Tolgee](i18n-tolgee.md)):

- the language is a `$lang` enum folder (`/en`, `/fr`; `/xx` is not found), read by `MaterialApp.router(routerConfig: TranslationScope.routerConfig(router, localeOf: localeSegment()))`;
- `startup()` reads `assets/i18n/en.arb` and `fr.arb` while `splash.dart` shows, so the first frame is translated, and `fr.arb` lacks one key on purpose: the page shows the English text;
- a layout with a button per language (no dropdown) that navigates with `relocate`, so `/en/products` becomes `/fr/produits` (a `route.dart` `paths` spelling);
- an ICU plural (`=0`, `one`, `other`) in one string;
- tests with `pumpRouter(app: ...)`, `FakeTranslations` as the over-the-air source and `fakeTranslations(...)` for a strict catalog: the first frame, a deep link in French, the switch changing the URL and the text, the fallback, a fetched text, an offline source and a missing key.

```sh
cd examples/i18n
flutter create --empty . --platforms=android,ios,web
flutter run
```

## maps

`examples/maps` (since 0.13.0) is [`fespalier_maps`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_maps): a pin picker that returns a place, and one offline map pack ([Maps](maps.md)).

- `/` asks "Where should we deliver?" with `await PickPlaceRoute().push<PickedPlace>(context)` and shows the point it gets back and the name as a best guess;
- `/pick-place` is `PinPicker` as the whole body, over `MapLibreSurface` and `GeolocatorPositionSource`, with the guess card, the search field and the confirm button as widgets of the app;
- `/offline` is one region pack (`tilePacks`): download, progress, pause, resume and delete;
- the geocoder is a fixed list of six cities in the app, so there is no geocoding service and no network call, in the app or in the tests;
- the style is MapLibre's demo style, for trying things out; `--dart-define=MAP_STYLE_URL=...` points at your own tiles.

```sh
cd examples/maps
flutter create --empty . --platforms=android,ios   # adds the platform folders, .gitignore and .metadata
flutter pub get
flutter run                                  # a device or a simulator: a map does not draw in `flutter test`
```

Add the location strings `geolocator` needs first (`NSLocationWhenInUseUsageDescription`, `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`; [Install](maps.md#install)). Its tests use `FakeMapSurface`, `FakePositionSource` and `FakeOfflineTiles` ([Testing](maps.md#testing)): pan, a guess and confirm; no name far from every city; a refused position as a hint; a late fix that does not override a pan; a search that is submitted, not sent per keystroke; and a pack's progress to complete, pause and resume.

## adopt

`examples/adopt` is a go_router app half-way through adopting fespalier, for [Migration](migration.md#adopting-fespalier-in-a-go_router-app):

- the hand-written routes nobody has moved (`/`, `/legacy/orders/:id`) beside fespalier's tree mounted with `AppRoutes.mount(at: '/shop', navigatorKey: ...)`, and the old product URLs redirected to the typed routes (`/products/2` becomes `/shop/products/2`);
- `app.dart`'s `router()` returns that hand-built `GoRouter` under the default `main: auto`, so `startup.dart` can have `ready(container)` and `attach(router, container)` ([`main()`](app-startup.md), since 0.12.0): the move of a 0.11-style `main()` that built its own `ProviderContainer`;
- `lib/before/` keeps the app as it was (a pure go_router version of the same screens, and its old `main()`), compiled, and `test/parity_test.dart` opens the same URLs in both and checks they show the same screens;
- tests for the mounted tree, the redirects, a typed route taken from a legacy page, and the order `ready()`, the router, `attach()` through `AppMain.root()`.

## offline

`examples/offline` (since 0.10.0) is [`fespalier_cratestack`](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_cratestack) with no server to start: two screens, and a switch in the app bar that plays the device's network.

- `/orders` reads with `ref.serve` (the `networkFirst` policy): with the switch off the list is the copy this phone last loaded, with its time, or "not loaded on this phone yet". Cancelling an order is an **intent** (`IntentQueue.submit`): saved, sent once under the key `<id>#<attempt>`, shown as "Cancelling, will send when back online" while queued, and sent when the network is back. A refusal (order 3 is already shipped) is shown and never retried.
- `/notes` are owned rows (`OwnedRows` and a `RowSync` the app writes): edited offline, merged with another phone's edit field by field, and rolled back out loud when the server refuses one.
- `autoSync` is watched once in the root `layout.dart`; the tick is a timer the app owns (`lib/foreground_ticker.dart`), and signing out wipes the account's queue first.
- The server is an in-process demo (`lib/demo/demo_server.dart`) behind the transport seam, so `flutter run` needs no backend; the tests use `FakeCrateStackTransport`, `FakeRowServer` and `ManualSyncTicker`, with no timer. Read it with [Offline-first](offline-first.md) and [CrateStack with fespalier](cratestack.md).
