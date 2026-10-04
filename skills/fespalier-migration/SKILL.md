---
name: fespalier-migration
description: "Moving to fespalier and between its versions — upgrading an app from 0.8 to 0.9 (a third-party telemetry sink needs a TelemetryOp.auth case; an app with telemetry: true regenerates app.g.dart, where data providers call data() through traceDataCall and the data span starts first and is current; the opt-in fespalier_auth package), 0.7 to 0.8 (the generated main(): app.dart, startup.dart and splash.dart at the app root, main: manual; hooks_riverpod ^3.2.1, the reserved freshness and dataCache names), 0.4 to 0.5 (pumpRouter disposes the router, new reserved names), 0.3 to 0.4 (publish_to none, currentLocation follows push) or 0.2 to 0.3 (regenerate app.g.dart with the matching fsp, PrefetchHandle replacing the timed prefetch, shell transitions, Riverpod retry now inherited, NotFoundScope, the hidden RouteMatch) and adopting fespalier in an existing go_router app by mounting its tree inside your GoRouter with AppRoutes.mount(at:), one folder at a time, siblings with a compound path (nest = false) included. Load before bumping the fespalier package or fsp, when an upgrade changes behaviour or fails to compile, or when planning a go_router-to-fespalier migration."
---

# fespalier-migration

> **Verified against fespalier `122cb07f` (2026-10-01), release v0.4.0.**
> These skills ship in the fespalier repository, and CI checks them against its code
> on every change. Version-sensitive claims say the release they became true in; if
> your app pins another fespalier, trust that release's code over this page. See
> [Versions](https://github.com/fespalier/fespalier/blob/main/skills/README.md#versions).

## The one rule of upgrading

**The package and `fsp` move together, and `lib/app.g.dart` is regenerated every time.**
The generated code relies on runtime additions of its own release; the upgrade notes of
0.1.1, 0.2 and 0.3 each say "regenerate", and so does every release since.

```sh
# 1. pubspec.yaml: bump `ref:` on the git dependency to the release tag, then
flutter pub get
# 2. regenerate with the fsp that matches the package your pubspec.lock resolved
dart run fespalier gen          # or: FSP_VERSION=<the same tag> install.sh, then `fsp gen`
# 3. commit lib/app.g.dart, then
flutter analyze && flutter test
```

`fsp --version` must print the package's version (`ref: vX.Y.Z` needs `fsp X.Y.Z`); an `fsp` of another
version on `PATH` is the usual source of an `app.g.dart` that does not compile.
`dart run fespalier` uses an `fsp` on `PATH` only when its version matches.

## 0.8 to 0.9: what to check

Bump to `v0.9.0`, regenerate (`lib/app.g.dart` is unchanged for an app that opts in to nothing), and look at these:

1. **A `FespalierTelemetry` sink that switches exhaustively over `TelemetryOp` stops compiling** (`The type 'TelemetryOp' isn't exhaustively matched by the switch cases since it doesn't match the pattern 'TelemetryOp.auth'`, and `'TelemetryOp.image'`). Add a `TelemetryOp.auth` case (it is what `package:fespalier_auth` reports, with
   `TelemetryStart.authStep`, `authBackend`, `authTrigger` and `authDpop`) and a `TelemetryOp.image` case (what `package:fespalier_image` reports, with
   `TelemetryStart.imageCdn`, `imageWidth` and `imagePreload`, and `TelemetryEnd.imageStatus`), or end the switch with `_ =>`.
   `fespalier_otel` and `RecordingTelemetry` have it. A sink with a `default`, or one that does not switch, is
   unaffected. `TelemetryOutcome` gains `none`, `expired`, `rejected` and `cancelled`, and
   `FespalierTelemetry.begin` and `finish` (for adapter packages).
2. **The telemetry conventions gain an `auth` and an `image` operation, with `fespalier.auth.*` and
   `fespalier.image.*` attributes**, within contract version 1 (new values of `fespalier.operation`, new keys): a
   dashboard that lists the operations shows two more. `fsp telemetry`'s dashboards label them "Session (sign-in,
   refresh, sign-out)" and "Image load".
3. **New, opt-in:** `package:fespalier_auth` ([`fespalier-guards`](../fespalier-guards/SKILL.md), its
   `auth-package.md`), with OpenID Connect and Keycloak (`package:fespalier_auth/oidc.dart`), a dio interceptor
   (`package:fespalier_auth/dio.dart`) and, as a separate package, device-bound tokens
   (`package:fespalier_sign_keypair`, DPoP; its `auth-dpop.md`). An app that adds `fespalier_sign_keypair` needs
   **Dart 3.12 and Flutter 3.44**, the same `url` and `ref` as `fespalier` and `fespalier_auth` for the three, and
   network access to `github.com/vaam-apps/flutter-sign-keypair` at `pub get` (it is a git dependency, not on
   pub.dev). Nothing else changes: no generated code, file kind, key or command.
4. **An app with `telemetry: true` regenerates a different `app.g.dart`.** Each data provider calls `data()`
   through `traceDataCall(ref, 'd4', id, () => _i5.data(ref, id: id), telemetry: ...)` instead of
   `traceData(ref, 'd4', id, _i5.data(ref, id: id), telemetry: ...)` (an app without `telemetry: true` is
   byte for byte unchanged). It costs one closure per provider build, with no `Future` and no microtask.
   What follows: a `data` span **starts before `data()` runs**, so its duration includes the synchronous part;
   a `data()` that throws before it returns now gets a `data` span (`fespalier.data.state = error`,
   `fespalier.async = false`; before 0.9.0 it got none); and `FespalierOtel` makes data and action spans
   current while they run, so the spans of `otel_http` and `otel_dio` made inside are their children.
5. **New, opt-in:** `package:fespalier_image` ([`fespalier-images`](../fespalier-images/SKILL.md)): a
   `ResponsiveImage` that fetches a network image at the width its box needs through an image CDN (imgproxy,
   EmgR, Cloudinary, imgix, Thumbor, a template or a signed srcset), and `RouteLink(onPreload:)` in fespalier
   itself, which runs a callback when a link starts a preload (a nullable parameter: nothing changes for a link
   that does not pass it). The same `url` and `ref` as `fespalier` for the two. No generated code, file kind,
   key or command changes.
6. **New, opt-in, in `fespalier-observability`:** `FespalierTelemetry.combine` and `add` (several sinks in
   the one slot, each with its own tokens and isolated), the `within` hook a sink may override (an instance
   member with a default, so a sink compiles unchanged unless it already had a member named `within` with
   another signature: rename it), `FespalierTelemetry.run` for adapter packages, and `navigateFrom` with
   `NavigationSource` and the attribute `fespalier.navigation.source` (contract version 1 gains a key; absent
   unless a bridge marks the navigation). `RecordingTelemetry` gains `recordWithin:` and `source=`.
7. **The package asks for `hooks_riverpod: ^3.3.2`** (it was `^3.2.1`): on riverpod 3.2.1, the lowest the old
   constraint admitted, a closed `PrefetchHandle` left its provider alive and `freshness` did not load again.
   An app already resolves 3.3.2 or newer; one pinned lower must raise its own constraint.

## 0.7 to 0.8: what to check

Bump to `v0.8.1`, regenerate, and look at these:

1. **`unknown_path` checks segment types.** The string-path lint (`lints: unknown_path`)
   now also reports a literal path that reaches a route whose segment cannot parse it:
   `` `/products/abc` reaches /products/:id, but `abc` is not an int, so it shows not-found
[unknown_path] `` (on one line). It is the same id and level, so an app with
   `unknown_path: error` that passed on 0.7.0 can fail on 0.8.1, for a path that always
   showed not-found. Fix the literal, use the typed route, or `// fsp:ignore unknown_path`.
   Messages and what is checked: `fespalier-troubleshooting`, "String paths"
   in its diagnostics reference.
2. **The package asks for `hooks_riverpod: ^3.2.1`** (it was `^3.0.0`): `Ref.mounted` is right for a stale ref and a
   paused provider resumes, which `freshness` relies on, and the experimental `persist()` that `dataCache` is built on
   is there. An app already resolves 3.4.x; one pinned lower must raise its own constraint.
3. **An app that opts in to nothing regenerates with DevTools-only changes.** A data route's view now watches through
   `watchData(ref, 'dN', provider)` and `lib/app.g.dart` gains a `_devToolsProviders()` map that `devToolsRegister`
   receives. `watchData` returns `ref.watch(provider)` unchanged (a pass-through: no `Future`, no microtask, and in a
   release build it is `ref.watch`) and the map is only read under `kFespalierDevTools`, so behaviour, timing and the
   release build are the same; only the diff of the generated file is new.
4. **`freshness` and `dataCache` are now names `fsp` reads in a `data.dart`.** A public top-level variable of that name and
   another type is an error (`` `freshness` must be a `Freshness(...)` ``); rename it. A private `_freshness` is never read.
   A `route.dart` may hold `const freshness = Freshness(...)` too (the "expected ..." error now names seven constants).
5. **New, opt in:** `Freshness` (`staleTime`, `refetchOnResume`, `refetchOnReconnect`), `DataCache` with
   `dataCacheStorage` and `MemoryDataStorage`, `package:fespalier/persist.dart`, and the `fresh` and `cached` tags of
   `fsp routes`. A route that opts in keeps its page when a reload fails (the freshness page of [`fespalier-data`](../fespalier-data/)).
6. **A `lib/app/app.dart`, `startup.dart` or `splash.dart` at the root that is something else** is the one thing that can
   break: `fsp` reads them now (`main: auto`) and errors with "the app's widget gets the router: ...". Move the file into
   `_components/`, or set `main: manual`. Moving a hand-written `main()` to the generated `AppMain` is optional; the
   table is in [`references/upgrading-0-7-to-0-8.md`](references/upgrading-0-7-to-0-8.md). An app with none of the
   three gets no new file (`lib/app.main.g.dart` is written only when one exists, or with `main: generated`).
7. **New, opt-in:** `observe.dart` (`onEnter`, `onFocus`, `onLeave` per page), the `telemetry` key,
   `package:fespalier_otel`, `RecordingTelemetry` and `fsp new --observe`. See
   [`fespalier-observability`](../fespalier-observability/SKILL.md).
8. **`fsp new` with nothing to create** now lists `--observe`: `nothing to create: ... also pass --action,
--layout, --loading, --error, --not-found, --guard, --observe or --transition`.
9. **A new tag on `fsp routes`**: a page with an `observe.dart` at or above it is tagged `observe` (and
   `--json` `tags` and the route tree's `markers` gain the value); consumers that match tags
   exactly should accept it.
10. **`otel_zone` pins go_router 17** (through `otel_go_router`). fespalier accepts 17 and 18; add
    `dependency_overrides: go_router: ^18.0.0` to stay on 18.
11. **`DeferredLibrary` has an optional `route`** (the generator sets it with `telemetry: true`), and
    `traceGuard` and `traceData` take an optional `telemetry:`; nothing to do unless you call them yourself.
    An app with no `observe.dart` and no `telemetry: true` gets none of items 7 to 11 in `app.g.dart`:
    no `TelemetrySite`, no `AppRoutes.attach`, no `observe:` (the generator's `no_companions` test pins it).

## 0.4 to 0.5: what to check

Bump to `v0.5.0`, regenerate, and look at these:

1. **`pumpRouter` disposes the router when the test ends.** A test that registered
   `addTearDown(router.dispose)` before calling it now fails with _A
   GoRouteInformationProvider was used after being disposed_, because that teardown runs
   after `pumpRouter`'s. Delete the line, or, since 0.6.0, keep it and pass
   `disposeRouter: false`.
2. **New reserved names.** Every typed route gains `preload`, `of`, `maybeOf` and
   `copyWith`, so a segment or query parameter with one of those names is refused by
   `fsp`; rename it. An `action.dart` function can't use them either.
3. **`AppRoutes.router()` without a `navigatorKey` makes a fresh one**, so tests no longer
   share a navigator through the generated class. A test that mounts under a prefix
   restores the defaults with `addTearDown(AppRoutes.mount)`.
4. **New, and nothing changes unless you use it:** `action.dart`, `RouteLink` with
   `preload` (it brings in `url_launcher`), `XRoute.of(context)` and `copyWith`, guards
   and redirects that take a `Ref`, and `fsp links` / `fsp routes --graph`.

## 0.3 to 0.4: what to check

Nothing in the generated code or the runtime API breaks; bump, regenerate, and look at
these:

1. **The package is `publish_to: 'none'`.** It was never on pub.dev; keep the git
   dependency and move its `ref:` to `v0.4.0`.
2. **`currentLocation(tester)` follows a `push`** (the top of the stack). A test that
   asserted the old location after a push, or read
   `currentConfiguration.last.matchedLocation` to work around it, can now use
   `currentLocation`; one that expected the old value fails.
3. **Three diagnostics read differently** (folder names accept `A-Z`, a hand-written
   family keyed by a query parameter, an optional parameter of a non-query type). Only a
   test that matches `fsp`'s text notices.
4. **New: `const nest = false;` in `route.dart`** makes a route a sibling of the page
   above it, with a compound path (`fespalier-routing`). Nothing uses it unless you write
   it.

## 0.2 to 0.3: what to check

Six things can change behaviour or break the build; the full table, with what to do for
each, is in [`references/upgrading-0-2-to-0-3.md`](references/upgrading-0-2-to-0-3.md).

1. **`prefetch` returns a `PrefetchHandle` and lives until you `close()` it** (it lapsed
   after 30 s before); **`prefetchKeepAlive` is gone**. Pass `keepFor:` for timed behaviour.
2. **A `transition.dart` at or above a layout now animates that layout's shell too**
   (`fsp init` writes a root one, so most apps see it). Look at every layout; take
   `bool shell` in `transition()` to treat the shell differently.
3. **Generated `data()` providers keep Riverpod's automatic retry** (no more
   `retry: null`). Give the app `ProviderScope(retry: ...)` a policy or set
   `data_retry: none`; tests that count calls or leave timers will notice.
   `DataView` also keeps the old state on screen during a reload (`keep_previous`).
4. **`NotFoundScope` takes a named `caseSensitive:`** (hand-written scopes only).
5. **`fespalier.dart` hides go_router's own `RouteMatch`** for fespalier's; import
   `package:go_router/go_router.dart` (prefixed, or with `hide`) if you used it.
6. **`router()` and `mount()` gained `navigatorKey`**, and layouts are built as
   `pageBuilder` pages. Regenerate; nothing to write.

Plus new reserved names (`extra` as a segment; later, `of`, `maybeOf` and `copyWith`, since 0.5.0) and `pumpRouter`'s default of **no
retries**. Everything else in 0.3.0 is additive.

## Adopting fespalier in a go_router app

Mount the tree **inside** your router under a prefix and move routes one folder at a
time:

```dart
GoRouter(
  navigatorKey: rootKey,
  routes: [
    ...legacyRoutes,
    ...AppRoutes.mount(at: '/shop', navigatorKey: rootKey),   // pass YOUR router's key
  ],
  errorBuilder: (context, state) => AppRoutes.notFound(state.uri),
)
```

- `at` is the URL prefix: typed routes, `uri` in guards, `dataAt` and `match` all know it
  (`ProductRoute(id: 2).location` is `/shop/products/2`; a location outside the prefix
  is `null` for `dataAt`). **Mount once**: `mount` stores `at` and the key in static
  fields.
- **Pass the host router's own `navigatorKey`**; routes using `navigator.dart` or
  `present.dart` need it as their `parentNavigatorKey`.
- `mount` passes **no** `extraCodec`, `restorationScopeId`, `observers` or
  `initialLocation`: they belong to your router. Forward unknown URLs to
  `AppRoutes.notFound(state.uri)`.
- Move a route = a folder with a `page.dart`; a `ShellRoute` = a `layout.dart`; a
  stateful shell = a tab layout; a route `redirect` = `guard.dart`/`redirect.dart`;
  `pageBuilder` transitions = `transition.dart`; string paths = typed routes.
- **Siblings with a compound path.** A folder below a page nests under it, so a deep link
  to `/orders/1/refund/confirm` builds `/orders/1/refund` too. If your tree had
  `GoRoute(path: 'refund')` and `GoRoute(path: 'refund/confirm')` side by side on purpose,
  keep that shape with `const nest = false;` in `refund/confirm/route.dart` (0.4.0).

The step-by-step guide, with a compiled, tested host router, the mapping table and the
things `mount` does not carry, is in
[`references/go-router-adoption.md`](references/go-router-adoption.md).

## Also

- `fsp init` in an existing project **never overwrites** a file: it prints `skip  ... (exists)`.
- Keep `lib/app.g.dart` committed and add `dart run fespalier gen` plus
  `git diff --exit-code lib/app.g.dart` to CI: `fsp check` does not see a stale file.
- Releases are cut by release-please; each tag is a package and an `fsp` of the same
  version and takes the same steps (bump, matching `fsp`, regenerate). Read the root
  `CHANGELOG.md` entry of **that** release: its "BREAKING CHANGES" first (0.3.0 has an
  "Upgrading from 0.2" section instead).

If `fsp` or `flutter analyze` complains after an upgrade, see
[`fespalier-troubleshooting`](../fespalier-troubleshooting/).
