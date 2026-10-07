# Run the examples

Start with [`examples/minimal`](../examples/minimal), then read on for what each of the others shows.

## minimal

[`examples/minimal`](../examples/minimal) is the smallest app: `flutter create` + `fsp init` and three
pages (a class page, a function page and a `$id` page with a query parameter and a `data.dart`), with a
README that goes through each file and a few widget tests.

## shop

```sh
cd examples/shop
flutter create . --platforms=android,ios,web   # adds platform folders only
flutter pub get
flutter run
```

Things to try:

- `/products/13` fails once, so you see `error.dart` and **Retry**.
- `/products/abc`: the int parse fails, so you get `not_found.dart`.
- `/checkout` with an empty cart: the guard redirects to `/cart`.
- `/greet/you`.

Since 0.9.0 the product photos come from an [EmgR](https://github.com/vaam-apps/image-resizer) on this
computer, unsigned. `examples/shop/lib/images.dart` says how to run it (`ALLOW_UNSIGNED_REQUESTS=true`,
and `ALLOWED_SOURCES` set to the photos' origin) and which `--dart-define`s point it elsewhere. Without
a server each photo fails and shows the product's initial.

- Hovering a row precaches the photo at the size its page shows
  ([Precaching an image behind a link](responsive-images.md#precaching-an-image-behind-a-link)).
- The photo flies to the page as an [image hero](responsive-images.md#images-in-heroes).
- Its tests use `FakeImages`.

## features

`examples/features` covers the rest. Routing and layouts:

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

`examples/tabs` is a bottom navigation bar built as a tab layout:

- four tabs: one with nested pages, and a Library tab that is a tab layout of its own, with two inner
  tabs;
- a counter that survives switching tabs, `tabOptions`, and a cross-fading `container`;
- a Search tab that also answers `/recherche` (`route.dart` with `paths`);
- a full-screen route outside the tabs (`/settings`), and one that stays under `/profile` but renders on
  the root navigator (`/profile/edit`, `navigator.dart`);
- a Cupertino `transition.dart` that also moves the tab layout itself aside when one of those opens over
  it.

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
- `telemetry: true`, and a `main.dart` that wires `otel_zone` (on go_router 17, which `otel_zone`
  requires);
- tests that read the hooks' log and the spans from an in-memory exporter.

Since 0.9.0 that `main.dart` also starts Sentry (`SENTRY_DSN` is empty, so nothing is sent), an order
page has a `Refuse` button whose action throws, and `test/sentry_test.dart` shows the event with its
route, its file and the OpenTelemetry trace of the same call.

## auth

`examples/auth` (since 0.9.0) is [`fespalier_auth`](../packages/fespalier_auth):

- a sign-in form on an action;
- a `requireSignedIn` guard that comes back to where the user was going, and a `requireRole` one for
  `/admin`;
- orders pages whose two `data.dart` files call an API through `authHttpClient` (an expired token is
  refreshed once);
- a first frame that is the app, not a splash, because `startup()` restores the session with no network.

The API is an in-process server, so it runs and is tested with no network. To run against Keycloak, use
`--dart-define=OIDC_ISSUER=...` and the realm in `examples/auth/keycloak/`. With
`--dart-define=OIDC_ISSUER=demo --dart-define=DPOP=true` it signs in against the demo server's own
provider with device-bound tokens (DPoP), and its tests check every proof the way a server does.
