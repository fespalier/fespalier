# `guard.dart`, `redirect.dart` and `returnTo`

As of 0.5.0 (a guard that takes a `Ref` since then; 0.4.1 and earlier take a
`ProviderContainer`). The samples use a tiny session flag; `auth-patterns.md` builds the
real flow on it.

```dart
// lib/auth.dart
import 'package:fespalier/fespalier.dart';

class Flag extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// Whether someone is signed in: what `(members)/guard.dart` checks.
final session = NotifierProvider<Flag, bool>(Flag.new);

/// Extra clearance for `(members)/admin`.
final isAdmin = NotifierProvider<Flag, bool>(Flag.new);
```

## `guard.dart`

`guard.dart` exports `GuardResult guard(Ref ref, {...})`. It returns a
**location to redirect to**, or `null` to let the navigation through, and may be
async. It guards **every route at and below its folder**, and the folder needs no
`page.dart`: put one in a `(group)` or at the root to cover a whole section of
the app.

```dart
// lib/app/(members)/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/auth.dart';

// Guards /inbox, /admin and everything else in the group.
GuardResult guard(Ref ref, {required Uri uri}) =>
    ref.watch(session) ? null : LoginRoute(from: uri.toString()).location;
```

```dart
// lib/app/(members)/inbox/page.dart
import 'package:flutter/material.dart';

class InboxPage extends StatelessWidget {
  const InboxPage({super.key, this.folder});

  final String? folder;

  @override
  Widget build(BuildContext context) => Text('inbox: ${folder ?? 'all'}');
}
```

```dart
// lib/app/(members)/admin/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/auth.dart';

// A folder's own guard runs after the ones above it: only signed-in
// members get this far.
GuardResult guard(Ref ref) =>
    ref.watch(isAdmin) ? null : const InboxRoute().location;
```

```dart
// lib/app/(members)/admin/page.dart
import 'package:flutter/material.dart';

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('admin');
}
```

```dart
// lib/app/login/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/auth.dart';

class LoginPage extends ConsumerWidget {
  const LoginPage({super.key, this.from});

  /// Where the guard that sent us here wanted to go.
  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    onPressed: () {
      ref.read(session.notifier).set(true);
      // Only in-app locations count: anything else falls back to `/`.
      context.go(returnTo(from));
    },
    child: Text('Sign in${from == null ? '' : ' to see $from'}'),
  );
}
```

- **The signature.** The first parameter is the `Ref ref` (positional; `ProviderContainer c`,
  the form before 0.5.0, is still accepted and generates the code it always did), then
  **named** parameters: `uri` (the requested location, a `Uri`, query
  included), `extra` (see `fespalier-routing`), the **segments** of the guard's own
  folder and the ones above it (`{required String shop}`), and **query
  parameters** (optional and nullable, `String? ref`). A guard above `$id` cannot
  ask for `id`: `` `id` isn't a segment of this path (it has none) at or above its folder; ... `` Segments are typed like
  everywhere else. The return type may be `GuardResult` (`FutureOr<String?>`),
  `FutureOr<String?>`, `Future<String?>` or `String?`; anything else is
  `guard() must return GuardResult (a location to redirect to, or null)`.
- **A guard takes a `Ref`, not a `WidgetRef`.** A `WidgetRef` is
  ``a guard runs outside the widget tree: take `Ref` ``. It runs when a navigation
  reaches its routes, **and again when what it `ref.watch`es changes and its answer
  is now a different one** (since 0.5.0; the `ProviderContainer` form never does).
  The router is asked to run the redirects again, so a guard that watches the session
  moves you to login on sign-out, and back on sign-in, on any page it covers. Rules:
  - **Each navigation evaluates the guard anew**, in a fresh `autoDispose` provider:
    `ref.read` is never stale, and `extra`, lists and `Uri`s need no key. What the guard
    watches is shared with the rest of the app, so a data provider is fetched once.
  - **A guard that answers synchronously stays synchronous** (no frame, no blank first
    frame at boot); a `Future`, even a completed one, takes a frame. An async guard
    watches through `.future`: `await ref.watch(currentUser.future) == null`.
  - **One subscription per guard and route**, kept while the committed location runs
    it, dropped when a navigation commits without it, and closed with the app. A guarded
    page **under a pushed page** does not react until you pop back to it (the push
    dropped its subscription; popping runs the guard again).
  - **A change that does not change the answer does nothing.** A **sign-out runs the
    guard twice**: Riverpod recomputes it, then the router asks again.
  - **Don't `ref.keepAlive()`** in a guard: it keeps one provider alive per navigation.
  - **A guard that throws never refreshes the router**: on a navigation the error reaches
    go_router as any redirect's does; when a later run throws, the page you are on stays
    until the next navigation. The guard's provider does not retry.
- **Order.** Guards run **outermost first, and the first to return a location
  wins.** A folder with a page and its own guard keeps its guard for that page and
  everything nested in it; guards above it run first. A guard that returns a
  location sends the navigation there, and the target's own guards run in turn.
- **What gets generated.** Each page's `GoRoute` gets a `redirect` that calls, in
  order, the guards of the page-less folders above it and then its own (chained
  with `firstRedirect`, which stays synchronous until a guard returns a
  `Future`). A `Ref` guard is called as
  `refGuard(context, 'g8@3', (ref) => _i8.guard(ref, uri: state.uri))`: the string is a
  constant naming that guard on that route. Nested pages go through their parent's `redirect`, so **no guard runs
  twice**. There is **no `redirect` on a `ShellRoute` or `StatefulShellRoute`**:
  go_router runs a matched route's redirect for deep links and for navigation
  inside a shell, tabs included, so the page routes are enough.
- **An unparsable segment skips only the guards that read segments or query
  parameters.** When a path has a segment that does not parse (`/vault/abc` where
  `id` is an `int`), a guard that asks for `{required int id}` (or any segment or
  query parameter) has nothing to be given, so `guardWithParams` skips it and
  not-found is shown. A guard that asks for **neither** (only `uri` and `extra`, or
  nothing) **still runs**: `/items/abc` under the `(members)` guard above goes to
  login first. (The 0.3.0 README said all guards are skipped; 0.4.0 corrected it.)
- **A guard's query parameters stay its own:** they do not become fields of the
  typed routes below it, unless the guard sits next to a `page.dart`, where they
  are the page's.
- A `guard.dart` with no `page.dart` or `redirect.dart` at or below its folder is a
  **warning** (`guard.dart guards no routes: ...`).
- **A guard is not a security boundary.** It decides what the router shows; the
  server must still authorise the data.

### Keep the login page out of the guard

A guard covers **every** route at and below its folder. If `login/` sits under it,
the guard sends the login page itself to `/login?from=...`, and so on; go_router
gives up after its redirect limit and the router's error builder shows your
`not_found.dart`: **"Nothing at /login"**, with the location stuck on `/`. Put
`login/` **outside** the guarded folder, as above: the guard is in `(members)/`,
the login page beside it. (A guard that returns exactly the location it is
already at, with no `from`, does not loop.)

## `redirect.dart`

A folder can hold `redirect.dart` **instead of** `page.dart`. It exports
`String redirect({...})` (or `Future<String>`) returning the location to go to; the
route only redirects, with no widget and no builder.

```dart
// lib/app/old-inbox/redirect.dart
import 'package:my_app/app.g.dart';

// /old-inbox?folder=sent becomes /inbox?folder=sent
String redirect({String? folder}) => InboxRoute(folder: folder).location;
```

- It takes the same parameters as a guard, except that **the first one is optional**:
  `Ref ref` (since 0.5.0) or the older `ProviderContainer c`, if you need providers. It
  runs once per navigation and does not watch: a redirect route never stays on screen.
  A `WidgetRef` is ``a redirect runs outside the widget tree: take `Ref` ``. Segments
  are typed like anywhere else, so `/old-products/abc` shows not-found.
- It gets a **typed route named after its path** (`OldInboxRoute()`,
  `OldProductsIdRoute(id: 3)`), so links to the old URL stay typed; query
  parameters it asks for are its fields.
- It takes part in route order and unreachable checks like a page, **inherits the
  guards above it**, and can sit next to a `guard.dart`, which runs first.
- A folder has a `page.dart` **or** a `redirect.dart`, not both; a tab layout's own
  folder cannot hold one. Routes in subfolders sit **beside** a redirect route, not
  inside it, since anything inside would redirect too.
- Return type: `String`, `FutureOr<String>` or `Future<String>`, or
  `redirect() must return the location to go to: a String (or Future<String>)`.
- The route table tags it `redirect`, and the manifest's `presentation` is
  `RoutePresentation.redirect` (`RouteInfo.isRedirect`).

## `returnTo`: sending people back

A guard that redirects to a login page can pass along where the user was going:
ask for `Uri uri` and put it in the login route's query.

```dart
LoginRoute(from: uri.toString()).location   // /login?from=%2Finbox%3Ffolder%3Dsent
```

`login/page.dart` takes it as a query parameter (`this.from`, a `String?`), and
when the user is done it calls **`returnTo`**:

```dart
context.go(returnTo(from));                  // from if it's a location in the app, else '/'
context.go(returnTo(from, fallback: '/home'));
```

`returnTo` lets only an **absolute in-app path** through: `https://...`, `//host`,
`/\host` and `javascript:` all fall back, so a crafted `?from=` cannot send people
off your app. Both `uri` and the typed routes include the mount prefix when the tree
is mounted with `at:`.
