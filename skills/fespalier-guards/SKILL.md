---
name: fespalier-guards
description: "Guarding and redirecting routes in fespalier — guard.dart (a function over a Riverpod Ref that returns a location or null, for a folder and everything below it, in page-less groups too, and that runs again when what it watches changes), redirect.dart routes, the order guards run in, the uri parameter and returnTo for sending people back after sign-in, async guards, and auth patterns such as a session provider, a login page outside the guarded folder, and sign-out moving you to login. Load before adding a guard or redirect, wiring sign-in and sign-out, or when a guard loops, never runs, or shows not_found.dart at the login page."
---

# fespalier-guards

> **Verified against fespalier `122cb07f` (2026-10-01), release v0.4.0.**
> These skills ship in the fespalier repository, and CI checks them against its code
> on every change. Version-sensitive claims say the release they became true in; if
> your app pins another fespalier, trust that release's code over this page. See
> [Versions](https://github.com/vaam-apps/fespalier/blob/main/skills/README.md#versions).

## A guard

```dart
// (members)/guard.dart: guards /inbox, /admin and everything in the group
import 'package:fespalier/fespalier.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/auth.dart';

GuardResult guard(Ref ref, {required Uri uri}) =>
    ref.watch(session) ? null : LoginRoute(from: uri.toString()).location;
```

`GuardResult` is `FutureOr<String?>`: **a location to redirect to, or `null` to
let the navigation through**; it may be async, but return synchronously when you
can (any `Future`, even `Future.value(...)`, costs a frame and a blank first frame on a
cold deep link). A guard covers **every route at and
below its folder**, and the folder needs no `page.dart`: put the guard in a
`(group)` (or at the root) to cover a whole section.

- **Parameters.** First the `Ref ref` (positional; the older `ProviderContainer c` is
  still accepted), then **named**:
  `uri` (the requested location, query included), `extra`, the segments of its own
  folder and above (`{required String shop}`), and optional nullable query
  parameters. A guard **above** `$id` cannot ask for `id`.
- **Order.** Outermost first; **the first guard to return a location wins**; a
  folder's own guard runs after the ones above it, so an inner guard may assume what
  an outer one checked. The location a guard returns is navigated to and **its** guards
  run in turn.
- **No double runs.** Each page's `GoRoute` gets the `redirect`; nested pages go
  through their parent's, and shells get none (go_router runs a matched route's
  redirect for deep links and for navigation inside shells, tabs included).
- **It takes a `Ref`, not a `WidgetRef`** (a guard has no widget:
  ``a guard runs outside the widget tree: take `Ref` ``). **`ref.watch` a provider
  and the guard runs again when it changes** (since 0.5.0): if the new answer differs
  from the one the navigation used, the router runs the redirects again. Signing out
  on `/inbox` moves you to login by itself. See "Signing out moves you" below.
- **Stay sync when you can.** A guard that answers synchronously adds no frame and
  boots with no blank first frame; **any** `Future`, even a completed one, costs a
  frame. Return a `Future` only when you await something.
- A `guard.dart` with no route at or below its folder is a **warning**.
- **To redirect, use a guard, not an `onEnter`** (since 0.8.0): an `observe.dart` hook runs after the
  navigation committed and cannot veto it. See [`fespalier-observability`](../fespalier-observability/SKILL.md).
- **A guard is not access control**: the server must still authorise the data.

## Keep the login page outside the guard

A guard covers everything below it, so a `login/` folder inside the guarded group is
redirected to itself (`/login?from=/login?from=...`); go_router gives up at its
redirect limit and the router's error builder shows your `not_found.dart`:
**"Nothing at /login"**, location stuck where it was. Put `login/` **beside** the
guarded group, never inside it.

## Sending people back

```dart
LoginRoute(from: uri.toString()).location   // /login?from=%2Finbox%3Ffolder%3Dsent

// login/page.dart, when sign-in succeeds:
context.go(returnTo(from));                  // from if it is an absolute in-app path, else '/'
context.go(returnTo(from, fallback: '/home'));
```

`returnTo` lets only an **absolute in-app path** through; `https://...`, `//host`,
`/\host` and `javascript:` all fall back, so a crafted `?from=` cannot send people
off your app.

## `redirect.dart`

```dart
// old-inbox/redirect.dart: /old-inbox?folder=sent -> /inbox?folder=sent
import 'package:my_app/app.g.dart';

String redirect({String? folder}) => InboxRoute(folder: folder).location;
```

A folder has a `redirect.dart` **instead of** a `page.dart`. It takes a guard's
parameters (the first one, `Ref ref`, is optional since 0.5.0, as is the older
`ProviderContainer c`), inherits the guards above it, gets a typed route named after its
path (`OldInboxRoute`), and its target's guards run in turn. A tab layout's own folder
cannot hold one. It runs once per navigation and does not watch: a redirect route
never stays on screen.

## Two behaviours that surprise

- **An unparsable segment skips only the guards that read segments or query
  parameters.** `/vault/abc` (an `int id`) skips a `guard(..., {required int id})`
  and shows not-found, but a guard that asks for neither (for instance the
  `(members)` one above, which takes only `uri`) **still runs**, so `/items/abc`
  under it redirects to login first. (The 0.3.0 README said all guards are skipped.)
- **Signing out moves you, if the guard watches (since 0.5.0).** A guard that
  `ref.watch`es the session runs again when it changes, with `AppRoutes.router()` and
  with a router of your own built from `AppRoutes.mount()`, with no
  `refreshListenable`. Three limits: a guard **under a pushed page** does not react
  until you pop back to it (the push dropped its subscription, popping runs the guard
  again); a guard that takes `ProviderContainer c` (or only `ref.read`s) never runs
  again by itself, as on 0.4.1 and earlier, where **no** guard did; and a sign-out runs
  the guard **twice** (Riverpod recomputes it, then the router asks), without
  fetching the providers it watches twice. **Don't `ref.keepAlive()` in a guard**: it
  leaks a provider per navigation. A guard that throws never moves the router.
  Details and a compiled sample: [`references/auth-patterns.md`](references/auth-patterns.md).
- **DevTools shows each decision (since 0.7.0).** Its **Guards** tab lists every guard and
  `redirect.dart` that answered, with `pass`, `redirect` (and where to), `pending` or `error` for an
  async guard, or `skipped` when a segment did not parse; a redirect chain is one history entry.
  The generated `redirect:` wraps each call in `traceGuard`, which returns the guard's own result, so
  a sync guard stays sync (`fespalier-troubleshooting`, its DevTools page).

## Where to read more

| Need                                                                | Reference                                                                  |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Every guard and redirect rule, compiled samples, `returnTo` details | [`references/guards-and-redirects.md`](references/guards-and-redirects.md) |
| Session provider, sign-in/out, guards that re-run, async guards     | [`references/auth-patterns.md`](references/auth-patterns.md)               |
| Testing a guarded route                                             | `fespalier-testing`                                                        |
| An `fsp` error on a guard or redirect                               | `fespalier-troubleshooting`                                                |
