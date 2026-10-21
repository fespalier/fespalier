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
async (but return synchronously when you can: any `Future`, even `Future.value(...)`,
costs a frame and a blank first frame on a cold deep link). It guards **every route at and below its folder**, and the folder needs no
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
  - **A guard that throws never refreshes the router**: on a navigation its failure reaches go_router
    as a `GuardFailure` (since 0.21.0, on every go_router): the route's `error.dart` shows when it takes
    only `error`, `stackTrace` and `retry`, and the not-found view otherwise. go_router builds the error
    route as a bare page, so that `error.dart` builds its own `Scaffold` and says something a person can
    act on (not the exception). The failure is reported once, in every build mode
    (`FlutterError.reportError`: library `fespalier`, context `while running a guard or redirect.dart`),
    so it reaches `FlutterError.onError`, where `SentryFlutter.init` listens, and a widget test calls
    `tester.takeException()`, as it does for a failed `startup()`. With `FespalierSentry` next to
    `SentryFlutter.init`, a failure after an `await` is still one event: the sink's, tagged with the route
    and the file, comes first, and the report carries the same error object, which Sentry's deduplication
    (on by default, `enableDeduplication`) drops; with deduplication off it is two. One before the guard
    returns is the report alone. The navigation ends with the telemetry outcome `error` (the Errors
    dashboard counts it in "Did a failing check stop a screen from opening?"). After `go` the page it was
    on is left; after `push` it stays under the error view, covered and not left, and it gets `onFocus`
    when the view closes; `pushReplacement` and `replace` over other pages leave the page they replaced.
    A guard that throws before it returns has no DevTools record and no guard span. When a
    later run throws, the page you are on stays until the next navigation. The guard's provider does not
    retry. Test it by the error route (after `go`, `router.routerDelegate.currentConfiguration.error` is a
    `GuardFailure`; after `push` it is `null`, so look at the error view), never by the exception's message.
  - **After `push`, `pushReplacement` and `replace` over other pages** go_router keeps the failed list in
    an entry on top of the stack, and the router's own `error` stays `null`. The error view, the report and
    the outcome `error` are the same. `retry` closes that entry and pushes the same location and `extra`
    again; the `Future` of the failed `push` completes with `null` when the entry closes, and the pushed page
    of the retry has no `Future` that anyone awaits. A retry pressed from a dialog or a sheet over the error
    view closes it first (since 0.21.0), so the retry replaces the error view and not the dialog. A retry held
    after the entry closed, or while a page is pushed over it, does nothing.
  - **A refresh does not run a pushed page's guard** (go_router, fespalier/fespalier#258): `refresh()`
    restores every pushed page without running its redirects, in a plain `GoRouter` too, on 17.2.3 to
    18.1.1, and fespalier does not work around it. A pushed page whose guard turns to refuse (a sign-out,
    a role revoked) stays on screen, unless the page at the bottom of the stack refuses too, whose
    redirect then replaces the whole stack. After a pushed navigation failed its guard, a later refresh
    shows the guarded page; since 0.21.0 fespalier's own re-evaluation no longer triggers that (the guards
    a failed navigation ran are closed as it commits), but an app's own `refresh()` or
    `refreshListenable` still does, and `retry` does not refresh. Put a guard that must react in a folder
    above every page it covers (the root `guard.dart` for a session), and open a page that must never
    show with `go`, not `push`.
- **Order.** Guards run **outermost first, and the first to return a location
  wins.** A folder with a page and its own guard keeps its guard for that page and
  everything nested in it; guards above it run first. A guard that returns a
  location sends the navigation there, and the target's own guards run in turn.
- **What gets generated.** Each page's `GoRoute` gets a `redirect` that calls, in
  order, the guards of the page-less folders above it and then its own (chained
  with `firstRedirect`, which stays synchronous until a guard returns a
  `Future`). A `Ref` guard is called as
  `refGuard(context, 'g8@3', (ref) => _i8.guard(ref, uri: state.uri))`: the string is a
  constant naming that guard on that route. (Since 0.7.0 every guard and redirect call is wrapped in
  `traceGuard(state, 'g8@3', ...)`, which returns the call's own result: DevTools shows the decision.)
  Nested pages go through their parent's `redirect`, so **no guard runs
  twice**. A plain `ShellRoute` gets no `redirect` (go_router runs a matched route's redirect for deep links and for
  navigation inside a shell, so the page routes are enough). Since 0.11.0 a guard **above a tab layout** runs once, as the
  `StatefulShellRoute`'s own `redirect:`, instead of being copied into each tab's route; it still runs for every location
  under the tabs, before the tab's own guards (`docs/migration.md`, 0.11.0).
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
