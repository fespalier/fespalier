# Auth patterns: sign-in, sign-out and refreshing on auth change

As of v0.4.0. fespalier has **no auth feature**; it gives you guards that read a
`ProviderContainer`, `returnTo`, and typed routes. Everything below is an app
pattern on top of that, compiled and tested against v0.3.0.

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
"signed in" as a value the guard can `read`. Guards take a `ProviderContainer`, so
keep what they need in providers rather than in widgets.

## The guarded group, the login page and the way back

```dart
// lib/app/(members)/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/auth.dart';

GuardResult guard(ProviderContainer c, {required Uri uri}) =>
    c.read(session) ? null : LoginRoute(from: uri.toString()).location;
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
- **Guards run on navigation.** A guard decides when a navigation reaches a route.
  With `AppRoutes.router()`, **signing out while you sit on `/inbox` does not move
  you**: the page stays until the next navigation, and the guard fires then. That
  is fine when the sign-out button itself navigates (`context.go(const
LoginRoute().location)`); it is not when the session can end elsewhere (a token
  expiring, another tab). For that, refresh the router.

## Refresh on auth change

`AppRoutes.router()` takes `initialLocation`, `observers`, `restorationScopeId`
and `navigatorKey`, and **no `refreshListenable`**. To re-run the guards when the
session changes, mount the tree in a `GoRouter` of your own and give it one.
go_router then re-evaluates the redirects of the current location on every
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

## Waiting for the session to load

A guard may be **async** (`FutureOr<String?>`): useful when the session is read from
storage at startup.

```dart
// lib/app/(private)/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/app.g.dart';

final restored = FutureProvider<bool>((ref) async => true);

// Waits for the stored session, then decides.
GuardResult guard(ProviderContainer c) async =>
    await c.read(restored.future) ? null : const LoginRoute().location;
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
