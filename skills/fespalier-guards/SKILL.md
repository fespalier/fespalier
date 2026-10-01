---
name: fespalier-guards
description: "Guarding and redirecting routes in fespalier — guard.dart (a function over a ProviderContainer that returns a location or null, for a folder and everything below it, in page-less groups too), redirect.dart routes, the order guards run in, the uri parameter and returnTo for sending people back after sign-in, async guards, and auth patterns such as a session provider, a login page outside the guarded folder, and refreshing the router when the session changes. Load before adding a guard or redirect, wiring sign-in and sign-out, or when a guard loops, never runs, or shows not_found.dart at the login page."
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

GuardResult guard(ProviderContainer c, {required Uri uri}) =>
    c.read(session) ? null : LoginRoute(from: uri.toString()).location;
```

`GuardResult` is `FutureOr<String?>`: **a location to redirect to, or `null` to
let the navigation through**; it may be async. A guard covers **every route at and
below its folder**, and the folder needs no `page.dart`: put the guard in a
`(group)` (or at the root) to cover a whole section.

- **Parameters.** First the `ProviderContainer c` (positional), then **named**:
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
- **It reads a container, not a `WidgetRef`**: `c.read(provider)`. It runs when a
  navigation reaches its routes, **not** when a provider changes (see the refresh
  section below).
- A `guard.dart` with no route at or below its folder is a **warning**.
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
parameters (the `ProviderContainer` is optional), inherits the guards above it, gets
a typed route named after its path (`OldInboxRoute`), and its target's guards run in
turn. A tab layout's own folder cannot hold one.

## Two behaviours that surprise

- **An unparsable segment skips only the guards that read segments or query
  parameters.** `/vault/abc` (an `int id`) skips a `guard(..., {required int id})`
  and shows not-found, but a guard that asks for neither (for instance the
  `(members)` one above, which takes only `uri`) **still runs**, so `/items/abc`
  under it redirects to login first. (The 0.3.0 README said all guards are skipped.)
- **Signing out does not move you.** With `AppRoutes.router()` a guard only runs on
  navigation, and the router has **no `refreshListenable`**. To re-run guards when a
  provider changes, mount the tree in your own `GoRouter`
  (`AppRoutes.mount(navigatorKey: rootKey)`) and give it a `refreshListenable` that
  listens to the session. That router loses `extraCodec` and `restorationScopeId`
  unless you pass them yourself. A compiled sample is in
  [`references/auth-patterns.md`](references/auth-patterns.md).

## Where to read more

| Need                                                                | Reference                                                                  |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Every guard and redirect rule, compiled samples, `returnTo` details | [`references/guards-and-redirects.md`](references/guards-and-redirects.md) |
| Session provider, sign-in/out, refresh on auth change, async guards | [`references/auth-patterns.md`](references/auth-patterns.md)               |
| Testing a guarded route                                             | `fespalier-testing`                                                        |
| An `fsp` error on a guard or redirect                               | `fespalier-troubleshooting`                                                |
