# Auth patterns: sign-in, sign-out and refreshing on auth change

As of 0.5.0. fespalier has **no auth feature**; it gives you guards that take a
`Ref` (and run again when what they watch changes), `returnTo`, and typed routes.
Everything below is an app pattern on top of that. Guards took a `ProviderContainer` and
ran only on navigation before 0.5.0: see "On 0.4.1 and earlier" below.

## The session provider

```dart
// lib/auth.dart
import 'package:fespalier/fespalier.dart';

class Session extends Notifier<bool> {
  @override
  bool build() => false;

  void signIn() => state = true;

  void signOut() => state = false;
}

final session = NotifierProvider<Session, bool>(Session.new);
```

A real app holds a token or a user here, loads it from storage, and exposes
"signed in" as a value the guard can `watch`. Guards take a `Ref`, so keep what they
need in providers rather than in widgets.

## The guarded group, the login page and the way back

```dart
// lib/app/(members)/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/auth.dart';

GuardResult guard(Ref ref, {required Uri uri}) =>
    ref.watch(session) ? null : LoginRoute(from: uri.toString()).location;
```

```dart
// lib/app/(members)/inbox/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/auth.dart';

class InboxPage extends ConsumerWidget {
  const InboxPage({super.key, this.folder});

  final String? folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    children: [
      Text('inbox: ${folder ?? 'all'}'),
      TextButton(
        onPressed: () => ref.read(session.notifier).signOut(),
        child: const Text('Sign out'),
      ),
    ],
  );
}
```

```dart
// lib/app/login/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/auth.dart';

class LoginPage extends ConsumerWidget {
  const LoginPage({super.key, this.from});

  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    onPressed: () {
      ref.read(session.notifier).signIn();
      context.go(returnTo(from));
    },
    child: const Text('Sign in'),
  );
}
```

- **The login page sits outside the guarded folder**, beside `(members)/`. Under the
  guard it would be redirected to itself and end on your `not_found.dart` (see
  `guards-and-redirects.md`).
- **`uri` carries the whole location, query included**, so the user comes back to
  `/inbox?folder=sent`, not just `/inbox`. `returnTo(from)` accepts only
  absolute in-app paths.
- `LoginRoute(from: ...)` is typed: renaming the login folder breaks the build, not
  the guard.
- **Signing out moves you** (since 0.5.0). The guard `ref.watch`es the session, so when
  it changes the guard runs again; if its answer is now a different one (`null` became
  a location), the router runs the redirects again. Signing out on `/inbox` ends on
  `/login?from=%2Finbox`, and signing in on the login page lets the same guard through.
  That also covers a session that ends elsewhere (a token expiring, another tab). Nothing
  is wired up by you: it works with `AppRoutes.router()` and with a router of your own
  built from `AppRoutes.mount()`, with no `refreshListenable`.
- **What to know.**
  - A guard that `ref.read`s, or takes `ProviderContainer c`, runs only when you navigate.
  - A guarded page **under a pushed page** waits: it reacts once you pop back to it.
  - A sign-out runs the guard **twice** (Riverpod recomputes it, then the router asks
    again); the providers it watches are not fetched twice.
  - `ref.keepAlive()` in a guard keeps one provider alive per navigation: don't.
  - Keep a guard sync (`GuardResult`, no `async`) unless it must await: a `Future`, even a
    completed one, costs a frame and a blank first frame at boot.

A test for it (`pumpRouter` returns the container; nothing else navigates):

```dart
// test/sign_out_test.dart
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/auth.dart';

void main() {
  testWidgets('signing out on a member page moves to login', (tester) async {
    final c = await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/inbox'),
    );
    expect(currentLocation(tester), '/login?from=%2Finbox');

    c.read(session.notifier).signIn();
    final context = tester.element(find.byType(Navigator));
    const InboxRoute(folder: 'sent').go(context);
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/inbox?folder=sent');

    c.read(session.notifier).signOut();
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/login?from=%2Finbox%3Ffolder%3Dsent');
  });
}
```

## Refreshing the router yourself (optional)

You no longer need this for a guard that watches. Build your own `refreshListenable` only
when something that is not a provider should re-run the guards, or on 0.4.1 and earlier,
where `AppRoutes.router()` took `initialLocation`, `observers`, `restorationScopeId` and
`navigatorKey` and **no `refreshListenable`**. Mount the tree in a `GoRouter` of your own and
give it one; go_router then re-evaluates the redirects of the current location on every
notification, which is where your guards live.

```dart
// lib/router.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/auth.dart';

/// Notifies when the session changes: go_router's `refreshListenable`.
class SessionRefresh extends ChangeNotifier {
  SessionRefresh(ProviderContainer container) {
    _sub = container.listen(session, (previous, next) => notifyListeners());
  }

  late final ProviderSubscription<bool> _sub;

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}

GoRouter buildRouter(ProviderContainer container) {
  // Routes on the root navigator (navigator.dart, present.dart) need the
  // host router's own key.
  final rootKey = GlobalKey<NavigatorState>();
  return GoRouter(
    navigatorKey: rootKey,
    refreshListenable: SessionRefresh(container),
    routes: AppRoutes.mount(navigatorKey: rootKey),
    errorBuilder: (context, state) => AppRoutes.notFound(state.uri),
  );
}
```

```dart
// lib/main.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/router.dart';

void main() {
  final container = ProviderContainer();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: buildRouter(container)),
    ),
  );
}
```

What you give up by building the router yourself: `AppRoutes.router()` also passed
**`extraCodec`** (from `extra_codec.dart`) and offered `restorationScopeId`;
**`mount()` does neither**, so pass `extraCodec: extraCodec` (imported from
`lib/app/extra_codec.dart`) and your own `restorationScopeId` to `GoRouter` if you
use them. The `errorBuilder` above is what `AppRoutes.router()` sets; keep it so
unknown paths still show your `not_found.dart`.

### On 0.4.1 and earlier

A guard took `ProviderContainer c` (`c.read(session)`) and **ran only on navigation**:
signing out while you sat on `/inbox` did not move you until the next navigation. The
sign-out button had to navigate itself (`context.go(const LoginRoute().location)`), or the
app had to build a router with a `refreshListenable` like the one above. The container
form still works on 0.5.0 and later, with that behaviour.

## Waiting for the session to load

A guard may be **async** (`FutureOr<String?>`): useful when the session is read from
storage at startup. It watches through `.future`, and runs again when that provider
changes, like a sync one.

```dart
// lib/app/(private)/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/app.g.dart';

final restored = FutureProvider<bool>((ref) async => true);

// Waits for the stored session, then decides.
Future<String?> guard(Ref ref) async =>
    await ref.watch(restored.future) ? null : const LoginRoute().location;
```

```dart
// lib/app/(private)/profile/page.dart
import 'package:flutter/material.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) => const Text('profile');
}
```

Guards chain with `firstRedirect`, which stays synchronous until one of them returns a
`Future`, so a synchronous guard above an async one does not make the route
async.

## Other patterns

- **Roles.** Nest guards: `(members)/guard.dart` checks "signed in",
  `(members)/admin/guard.dart` checks the role. The outer one runs first, so the
  inner one can assume a session (see `guards-and-redirects.md`).
- **Per-resource checks.** A guard that asks for a segment
  (`{required String shop}`) can refuse one value; it is skipped for an unparsable
  segment.
- **Old URLs.** Put `redirect.dart` in the old folder; it is guarded in turn.
- **Testing.** Sign in by writing to the provider through the container
  `pumpRouter` returns (`c.read(session.notifier).signIn()`), then navigate with a
  typed route. See `fespalier-testing`.
