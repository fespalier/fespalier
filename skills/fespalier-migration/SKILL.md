---
name: fespalier-migration
description: "Moving to fespalier and between its versions — upgrading an app from 0.11 to 0.12 (opt-in ready(container) and attach(router, container) in startup.dart: the gate makes the app's ProviderContainer, runs ready before the router and attach after the adapters'; no change for an app that exports neither), 0.10 to 0.11 (an app with an observe.dart regenerates: RouteHooks.onEnter takes a RouteScope, the generated main passes the container to AppRoutes.attach, and a replace of a tree page keeps its page instance; a third-party telemetry sink with an exhaustive switch on TelemetryOp needs a TelemetryOp.custom case; AppAdapters, main: manual with adapters, FespalierAdapter.attach, extends not implements; forms moved out of fespalier into the fespalier_forms package: an app with a form() adds the dependency at the same url and ref and regenerates, fsp errors until then, and code that names ActionForm, FieldCodec, ActionFormMessages and the rest imports package:fespalier_forms; FieldErrors, validate() and optimistic() stay; form drafts, opt-in, regenerate every app with a form and reserve the key name draft; multi-page forms, opt-in: a const steps map in a section's action.dart, and only a map literal called steps beside a form() is read as one), 0.9 to 0.10 (no generator or runtime change: app.g.dart is unchanged; the docs moved from the README to docs/ pages and some fsp messages now cite them; the opt-in fespalier_tolgee and fespalier_cratestack packages), 0.8 to 0.9 (a third-party telemetry sink needs a TelemetryOp.auth case; every app regenerates app.g.dart with page names, each pageBuilder wrapped in namedPage so a NavigatorObserver sees the route pattern; an app with telemetry: true also has data providers that call data() through traceDataCall, and the data span starts first and is current; the opt-in fespalier_auth and fespalier_dio packages and fespalier: adapters:), 0.7 to 0.8 (the generated main(): app.dart, startup.dart and splash.dart at the app root, main: manual; hooks_riverpod ^3.2.1, the reserved freshness and dataCache names), 0.4 to 0.5 (pumpRouter disposes the router, new reserved names), 0.3 to 0.4 (publish_to none, currentLocation follows push) or 0.2 to 0.3 (regenerate app.g.dart with the matching fsp, PrefetchHandle replacing the timed prefetch, shell transitions, Riverpod retry now inherited, NotFoundScope, the hidden RouteMatch) and adopting fespalier in an existing go_router app by mounting its tree inside your GoRouter with AppRoutes.mount(at:), one folder at a time, siblings with a compound path (nest = false) included. Load before bumping the fespalier package or fsp, when an upgrade changes behaviour or fails to compile, or when planning a go_router-to-fespalier migration."
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

## 0.11 to 0.12: what to check

0.12.0 changes nothing for an app that does not opt in: `app.g.dart` and `app.main.g.dart` regenerate to the same
bytes. New in `startup.dart` (since 0.12.0): `FutureOr<void> ready(ProviderContainer container)` and
`void attach(GoRouter router, ProviderContainer container)`, each optional. The gate makes the app's
`ProviderContainer` itself when `ready()` exists, runs it before the router is built, and calls `attach()` after the
first frame that shows the router, after the adapters' `attach`. The order is `zone()`, `startup()`, the container,
`ready()`, the router, `attach()`. `ready` and `attach` are reserved names in startup.dart: a helper of that name with another shape is now an `fsp` error (rename it or make it private). A `ready()` that throws goes to the splash's error and `retry`, which
disposes the container, makes a fresh one and runs `ready()` again (not `startup()`). To move a `main: manual` app's
`main()` over: its overrides to `startup()` (they are made before any container), the code between creating its
`ProviderContainer` and `runApp` (an `await container.read(x.future)`, an eager read, a `container.listen`) to
`ready()`, and the post-frame step that needs the router to `attach()`. Details: the `fespalier` skill's app-main reference; `docs/migration.md`, "0.12.0".

## 0.10 to 0.11: what to check

0.11.0 is a **breaking** release for apps with forms (`form()` in an `action.dart`); an app with none changes nothing. Bump the `ref:` of `fespalier` (and every companion) to the 0.11.0
tag, then:

1. **Add `fespalier_forms`** under `dependencies:`, at the **same git `url` and `ref` as `fespalier`** (the block is in
   `packages/fespalier_forms/README.md` and `docs/forms.md`), and run `fsp gen`. `app.g.dart` now imports
   `package:fespalier_forms/fespalier_forms.dart`, **only in an app with a `form()`**. Until the dependency is there `fsp`
   reports an error at each `form()`: `` `form()` is the form of `action()`, and since 0.11.0 forms are in the fespalier_forms
package: add `fespalier_forms` under `dependencies:` in pubspec.yaml, with the same git `url` and `ref` as fespalier ``.
2. **Imports of the form types.** Code that names `ActionForm`, `ActionField`, `ActionTextField`, `ActionFormFields`,
   `FieldCodec`, `ActionFormMessages`, `ActionFormValidation` or `useActionForm` imports
   `package:fespalier_forms/fespalier_forms.dart`: `package:fespalier/fespalier.dart` no longer exports them (no shim and no
   re-export). The names and the behaviour are the same, and a page that only calls the generated `useForm` needs no import.
3. **What stays in `fespalier`**: `FieldErrors`, `validate()` and `optimistic()`. A test of an action's `FieldErrors` or of
   `validate()` changes nothing; `fespalier_dio`, `fespalier_auth`, `fespalier_cratestack` and `fespalier_sentry` are
   unchanged. A test file that was `packages/fespalier/test/action_form_test.dart` in a fork is
   `packages/fespalier_forms/test/action_form_test.dart` now.
4. **Floor and CI**: `fespalier_forms` claims Flutter 3.32 like the packages it follows; a repository that copies this
   repository's `just floor` list adds it.
5. Where the form is documented now: the forms and optimistic pages of [`fespalier-data`](../fespalier-data/SKILL.md)
   (the one page it was part of is split in two).
6. **Drafts are new and opt-in, but every app with a `form()` regenerates.** `useForm` takes a `FormDraft? draft` and
   `useActionForm` gets the action's `id:`, `key:` and `shape:`; a `bool`, `DateTime` or enum field gets a `DraftCodec`.
   A key of an action with a form can no longer be called `draft` (`fsp` says `` `draft` can't be a key of an action with a
form: its hook, `useForm`, takes a parameter called `draft`; rename it ``). Drafts are kept in `formDraftStorage` (your
   `dataCacheStorage` by default): call `clearFormDrafts(ref)` at sign-out and give `formDraftScope` the account.
7. **Asking before unsaved changes go is new and changes no generated code.** A `leave.dart` that is
   `leaveIfClean(context, ref, page)` (from `fespalier_forms`) asks in a bottom sheet ("Keep editing", "Discard",
   "Keep as draft" for a form with a `draft:`); a `useForm` under a page with a `leave.dart` registers its form as the
   page's `LeaveSource` itself. The sheet is Flutter's (`showModalBottomSheet`), so an app on material_ui's
   `MaterialApp`, which has no `MaterialLocalizations`, overrides `leavePrompt` with its own sheet. See
   the forms reference of `fespalier-data`, "Leaving with unsaved changes".
8. **Multi-page forms are new and opt-in** (the flows reference of `fespalier-data`). A section's `action.dart` with a
   `const steps` map is a form over several pages that share one form and one draft; an app that adds none changes
   nothing. Only a map literal called `steps` (or `<action>Steps`) beside a `form()` is read as one from 0.11.0 (and
   reported when malformed); a `steps` of another shape is left alone. A flow section may have a page-less
   `leave.dart`. `LeaveScope.onBack` now blocks the pop on the first page of a navigator too.

### Route lifecycle

An app with an `observe.dart` regenerates `lib/app.g.dart`, and nothing else changes for a hook you wrote.

1. The generated closures read `onEnter: (ref, scope) => ...` now: `RouteHooks.onEnter` is
   `void Function(Ref ref, RouteScope scope)?`. A hand-built `RouteHooks` (a test, a fork) takes two parameters:
   `onEnter: (ref, _) => ...`. Run `fsp gen` with the 0.11.0 `fsp`.
2. `onEnter` may take `{required RouteScope scope}`: `scope.hold(provider)` keeps a provider (a route's `data`) loaded
   until the page is gone, a parked tab included, and `scope.onLeave(callback)` runs when it is gone. `onLeave` and
   `onFocus` cannot take it (an error). The page instance, the order at leave and the lifetimes are on
   [`fespalier-observability`](../fespalier-observability/SKILL.md)'s lifecycle page.
3. `AppRoutes.attach` takes the optional `ProviderContainer` in an app with an `observe.dart` too (it had it only with
   `adapters:`), and the generated `lib/app.main.g.dart` passes it (`attach: AppRoutes.attach`: regenerate both files).
   Hooks therefore run in the app's root container: a provider overridden only in a nested `ProviderScope` reads its
   default there. `AppRoutes.attach(router)` works as before.
4. A scope ends when its container is disposed too, so a `scope.onLeave` callback runs at the end of a `pumpRouter` test.
5. **Page ids changed for `replace`**: a page made by `replace` has the key of the page it replaced (go_router), and the
   lifecycle now uses it: `replace('/c/1?q=2')` on `/c/1` is no leave and enter, `replace('/c/2')` is. Telemetry page
   events and Sentry breadcrumbs follow. `push` and `pushReplacement` are unchanged. Test a hook with `TestRouteScope`
   (`package:fespalier/testing.dart`).

### Adapters

**An app without `fespalier: adapters:`
gets nothing from this part. An app with `adapters:` regenerates two files:**

1. `lib/app.g.dart` gains `AppAdapters` and the adapters' imports (`package:<name>/fespalier_adapter.dart as _a0`), and
   `AppRoutes.attach` takes an optional `ProviderContainer` and runs each adapter's `attach` with it.
2. `lib/app.main.g.dart` no longer imports the adapters: it calls `AppAdapters.zone`, `.beforeRun()`, `.wrap`,
   `.overrides()`, `.providerObservers()` and `.routerObservers()`, and gives the `StartupGate` `attach: AppRoutes.attach`.
3. `main: manual` with `adapters:` is accepted (0.10.0 refused it): call `AppAdapters` from your `main()` and
   `AppRoutes.attach(router, container)` once both exist (`fespalier`, app-main page).
4. `FespalierAdapter` has a new member, `attach(router, container)`, with an empty default. An adapter that
   **`implements`** `FespalierAdapter` (not `extends`) stops compiling: extend it.
5. `FespalierAdapter` also has `launch()` and `onEnter(InboundNavigation)` (empty defaults), and the runtime has `InboundLaunch`
   and `launchRouter`: a platform link is marked `NavigationSource.link` in telemetry when `launchRouter(links: true)` builds the
   router. The generated wiring is there too: `AppRoutes.router` takes `launch:` and passes `links: true` with telemetry or
   adapters, and with adapters there is an `AppRoutes.onEnter` (passed to `GoRouter(onEnter:)`) and `AppAdapters.launch()`, which
   the generated main asks once and hands to the router as `AppMain.launch`. Every app's `app.g.dart` changes (the router is built
   inside `launchRouter`: run `fsp gen`). An app.dart `router()` passes `launch: AppMain.launch` on (`fsp` warns otherwise); a
   `main: manual` app calls `AppAdapters.launch()` itself. Any `onEnter` makes go_router parse every navigation asynchronously and
   apply its redirect limit, so it is generated only with adapters.
6. Moving from `main: auto` to `manual`: delete `lib/app.main.g.dart`. Each adapter's top-level `adapter` is read once, at the first `AppAdapters` call. `attach` runs after the first frame that shows the router.

### Guards above tabs (0.11.0)

A guard above a tab layout (the tabs folder's own, or a page-less folder over it) is now generated once, on the `StatefulShellRoute`'s `redirect:`, not copied into each tab's route (`fsp gen`). Behaviour is the same; its telemetry and DevTools site is one, with the tab folder's pattern as `fespalier.route` (`/` for a group), so dashboards grouping guard outcomes by route see the tabs merged. A tab's own `guard.dart` stays on its route.

### Telemetry (0.11.0)

`TelemetryOp` gains `custom`, for a package's own operation (`FespalierTelemetry.begin` and `finish`; `TelemetryStart` has
new `name` and `attributes` fields and `TelemetryEnd` a new `attributes` field). **A `FespalierTelemetry` sink of your own
with an exhaustive `switch` on `TelemetryOp` stops compiling**: add a `TelemetryOp.custom` case or end the switch with
`_ =>`. The error says the switch does not handle `TelemetryOp.custom`. An app that uses only `FespalierOtel`,
`FespalierSentry` or `RecordingTelemetry` changes nothing. `FespalierSentry` does not send a `custom` failure as an event
unless you pass a `capture:` that returns true for it (the exception text is the package's).

## 0.9 to 0.10: what to check

Bump the `ref:` to the 0.10.0 tag, run the matching `fsp gen` as always, and expect **`lib/app.g.dart` unchanged**. This was
checked as of `bfbbf87f` (after 0.9.1): nothing the emitter writes, no runtime file of `package:fespalier` and no template
that `fsp new` or `fsp init` writes into an app changed behaviour since 0.9.1, only comments and the documentation pointers
of a few messages. Re-run `fsp gen` and `git diff lib/app.g.dart` on the release itself to confirm; a diff there is a bug to
report, not something to accept.

1. **The documentation moved.** The long README is now a short one, and the reference is one-topic pages under `docs/`
   (`docs/routing.md`, `docs/data.md`, `docs/i18n-tolgee.md`, ...). The old README anchors still work (the README keeps one
   per old heading, and `docs/README.md` maps them). **Some `fsp` messages cite a page now**, where 0.9 cited the README:
   `fsp init`'s pointer (`see docs/app-startup.md`), the `fsp run` and `tasks:` messages (``docs/cli.md, "Tasks: commands
around `flutter run`"``) and the warning `⚠ this app sends no fespalier spans yet ... (docs/observability.md,
"Telemetry")`. A CI step or a script that greps for the old `(README, "...")` text must follow; the message's meaning is
   the same.
2. **Two new, opt-in companion packages** with **no generator change** (no file kind, `fespalier:` key or `fsp` command):
   `fespalier_tolgee` (translated texts, the language from the URL: [`fespalier-i18n`](../fespalier-i18n/SKILL.md)) and
   `fespalier_cratestack` (offline-first reads, queued writes and sync, with a CrateStack client:
   [`fespalier-offline`](../fespalier-offline/SKILL.md), [`fespalier-cratestack`](../fespalier-cratestack/SKILL.md)). Like
   every companion, they take **the same `url` and the same `ref` as `fespalier`** (and `fespalier_cratestack` needs
   `fespalier_dio` at the same tag too). An app that does not depend on them is byte for byte what it was. **Neither ships a
   `fespalier_adapter.dart`**, so they go in `startup()`, not in `adapters:`.
3. **Adopting translations from `gen-l10n` or from the `tolgee` SDK** is not a mechanical change (keys become strings, the
   locale comes from the route, apostrophes before a brace are doubled): the steps are in
   [`fespalier-i18n`](../fespalier-i18n/SKILL.md) (its `messages-and-catalogs.md` page).
4. **Nothing to do for telemetry sinks**: 0.10.0 adds no `TelemetryOp` and no convention (contract version 1), so an
   exhaustive sink still compiles. Reads through `serve` and `submit` run inside the existing data and action spans.

## 0.8 to 0.9: what to check

Bump to `v0.9.0`, regenerate (`lib/app.g.dart` changes in every app, by its page names: item 10), and look at these:

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
   `traceData(ref, 'd4', id, _i5.data(ref, id: id), telemetry: ...)` (an app without `telemetry: true` keeps
   `traceData`). It costs one closure per provider build, with no `Future` and no microtask.
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
8. **New, opt-in:** `package:fespalier_dio` ([`fespalier-data`](../fespalier-data/SKILL.md), its `http.md`): `ref.cancelToken()` and
   `ref.abortable(client)`, `withFieldErrors()` and `WriteGuard` for Dio and `package:http`. A repository dependency
   with the same `url` and `ref` as `fespalier`; an app that does not add it is unchanged (no generated code, file kind,
   key or command).
9. **New, opt-in:** `package:fespalier_sentry` ([`fespalier-observability`](../fespalier-observability/SKILL.md)):
   Sentry, errors first (events tagged with the route pattern, the app file and the action, one breadcrumb per page
   change, the OpenTelemetry trace id on each event next to `fespalier_otel`; screen-load transactions only with
   `tracing: true`). The same `url` and `ref` as `fespalier`, and `sentry_flutter` 9.26.0 or newer. No generated code,
   file kind, key or command changes. `FespalierTelemetry` gains `traceOf` and `linkTrace` (instance members with
   defaults) and `TelemetryTrace`, which `combine` uses to tell a sink which trace an operation is in (`FespalierOtel`
   answers it): a sink that already had a member named `traceOf` or `linkTrace` with another signature must rename it.
10. **An app that opts in to nothing regenerates with page-name changes only (since 0.9.0).** Each `pageBuilder:`
    fespalier writes (a route with a `transition.dart` or `present.dart`, a `remount` route, a layout's
    shell) is wrapped in `namedPage('<pattern>', () => ...)`: two lines per page builder, the first
    gaining `namedPage('/products/:id', () =>` and the last a `)`. The pages `Transitions.*`,
    `layoutPage` and `remountPage` build are then named by their route pattern (`RouteSettings.name`),
    so a `NavigatorObserver` (Sentry's, Firebase Analytics', PostHog's) sees `/products/:id` where it
    saw `null` (a `remount` page saw `:id`). Keys, restoration ids, transitions and the release build
    are otherwise the same. A route with neither (a bare `builder:`) is go_router's own page and
    unchanged. With `telemetry: true` each `data.dart` provider also becomes
    `traceDataCall(..., () => data(...), telemetry: ...)` (item 4). A `transition.dart` that builds a
    `Page` of its own can pass `name: Transitions.pageName`.
11. **New, opt-in, in [`fespalier`](../fespalier/SKILL.md) (its app-main page):** the `fespalier: adapters:`
    key in `pubspec.yaml` (a list of package names), and `FespalierAdapter` in `package:fespalier/startup.dart`. Each listed
    package ships `lib/fespalier_adapter.dart` with a top-level `adapter`, and the generated `main()` calls its
    `zone`, `beforeRun`, `overrides`, `providerObservers`, `routerObservers` and `wrap`; the key makes `main: auto`
    write `lib/app.main.g.dart` on its own. An app without the key regenerates the same `lib/app.main.g.dart`
    as before. An `fsp` older than 0.9.0 rejects the key as an unknown field.

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
