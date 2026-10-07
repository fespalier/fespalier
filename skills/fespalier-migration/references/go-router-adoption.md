# Adopting fespalier in an existing go_router app

As of v0.4.0. You do not have to rewrite the router. fespalier's tree mounts **inside**
your `GoRouter` under a URL prefix, so you can move routes across one folder at a time
and keep the rest as they are.

## 1. Install

<!-- x-release-please-start-version -->

```yaml
# in pubspec.yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.12.0
```

<!-- x-release-please-end -->

It needs go_router **17 or 18** (check your constraint), hooks_riverpod **3** and
flutter_hooks, and **`package:fespalier/fespalier.dart` re-exports all three**, so your
existing imports keep working. The app needs a `ProviderScope` above
`MaterialApp.router` if it had none. Get `fsp` (`fespalier/references/cli-and-config.md`)
and run `fsp init` in the project root: it writes `layout.dart`, `page.dart`,
`not_found.dart` and `transition.dart` under `lib/app/` (never overwriting) and generates
`lib/app.g.dart`. Delete the starter files you do not want: a `layout.dart` wraps
everything below it.

## 2. Mount it

`AppRoutes.mount({at, navigatorKey})` returns the routes alone. `at` is the URL prefix;
pass **your `GoRouter`'s own `navigatorKey`**, because routes that render on the root
navigator (`navigator.dart`, `present.dart`) name it as their `parentNavigatorKey`, which
go_router requires to be an ancestor navigator's.

```dart
// lib/router.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class LegacyHome extends StatelessWidget {
  const LegacyHome({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const Text('legacy home'),
        TextButton(
          // A typed route into the mounted tree: the prefix is written for you.
          onPressed: () => const ProductRoute(id: 2).go(context),
          child: const Text('to the shop'),
        ),
      ],
    ),
  );
}

GoRouter buildRouter() {
  final rootKey = GlobalKey<NavigatorState>();
  return GoRouter(
    navigatorKey: rootKey,
    routes: [
      GoRoute(path: '/', builder: (context, state) => const LegacyHome()),
      GoRoute(
        path: '/legacy/:id',
        builder: (context, state) => Text('legacy ${state.pathParameters['id']}'),
      ),
      ...AppRoutes.mount(at: '/shop', navigatorKey: rootKey),
    ],
    // Unknown URLs: fespalier's nearest not_found.dart (the prefix is skipped when
    // looking for the folder, and a URL outside it gets the root's).
    errorBuilder: (context, state) => AppRoutes.notFound(state.uri),
  );
}
```

```dart
// lib/app/products/$id/page.dart
import 'package:flutter/material.dart';

class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) => Text('product $id');
}
```

```dart
// lib/app/(members)/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/app.g.dart';

// uri includes the mount prefix, and so does the typed route's location.
GuardResult guard(Ref ref, {required Uri uri}) =>
    LoginRoute(from: uri.toString()).location;
```

```dart
// lib/app/(members)/vault/page.dart
import 'package:flutter/material.dart';

class VaultPage extends StatelessWidget {
  const VaultPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('vault');
}
```

```dart
// lib/app/login/page.dart
import 'package:flutter/material.dart';

class LoginPage extends StatelessWidget {
  const LoginPage({super.key, this.from});

  final String? from;

  @override
  Widget build(BuildContext context) => Text('login from $from');
}
```

```dart
// lib/main.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/router.dart';

final _router = buildRouter();

void main() =>
    runApp(ProviderScope(child: MaterialApp.router(routerConfig: _router)));
```

What `mount` changes:

- **`AppRoutes.base` becomes `'/shop'`** (`mount` stores `at` in a static field), every typed
  route's `.location` includes it (`ProductRoute(id: 2).location` is `/shop/products/2`),
  and so do `uri` in guards and the `from` you pass around. `dataAt` and `match` strip it,
  and a location **outside** it is `null`. **Mount once.**
- **The tree's root `page.dart` is `/shop`**, and a `route.dart` `caseSensitive` at the root
  applies to the prefix too.
- Tab `initialLocation`s in `tabOptions` get the prefix added for you.
- **Not passed through `mount`**: `extraCodec` (import it from `lib/app/extra_codec.dart`
  and pass `extraCodec:` to your `GoRouter`), `restorationScopeId`, `observers`,
  `initialLocation`: they are the host router's.
- **Unknown URLs** reach **your** `errorBuilder`. Forward them to
  `AppRoutes.notFound(state.uri)`, as above, or users see go_router's own error screen.
- **Redirects**: fespalier's guards are `redirect`s on the mounted `GoRoute`s; your router's
  top-level `redirect` and `refreshListenable` still apply around them. A guard that
  takes a `Ref` and `ref.watch`es re-runs when what it watches changes (since 0.5.0), in your
  router too, with no `refreshListenable` (`fespalier-guards`); a host `refreshListenable`
  is only for a change that is not a provider (and for 0.4.1 and earlier).
- `AppRoutes.router()` is what you **stop** calling: it is `mount()` inside a router of its
  own.

## 3. Move routes over, one at a time

For each `GoRoute` you move:

| go_router                                                                    | fespalier                                                                                                                                                                                   |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `path: '/products/:id'` and a builder reading `pathParameters`               | folder `products/$id/`, a `page.dart` with `required int id` (typed: a bad id is not-found)                                                                                                 |
| `GoRoute(path: 'details')` nested under a parent                             | a subfolder `details/`                                                                                                                                                                      |
| `GoRoute(path: 'refund')` and `GoRoute(path: 'refund/confirm')` side by side | `refund/confirm/route.dart` with `const nest = false;` (0.4.0): it stays a sibling of `refund`, so a deep link does not build the `refund` page (`fespalier-routing`)                       |
| `ShellRoute(builder: (c, s, child) => Shell(child))`                         | a `layout.dart` with `Widget child` in the folder that holds the routes (or a `(group)`)                                                                                                    |
| `StatefulShellRoute.indexedStack(...)`                                       | a tab layout taking `StatefulNavigationShell` (`fespalier-layouts`)                                                                                                                         |
| `redirect: (context, state) => ...` on a route                               | `guard.dart` (a `Ref`, `uri`) or `redirect.dart` for a pure forward (`fespalier-guards`)                                                                                                    |
| `pageBuilder` with a transition                                              | `transition.dart` (`Transitions.fade`, ...) (`fespalier-layouts`)                                                                                                                           |
| `state.extra` read in the builder                                            | a nullable `extra` parameter (`fespalier-routing`)                                                                                                                                          |
| A FutureBuilder or provider loaded in the page                               | `data.dart` (a selector for a provider you already have) (`fespalier-data`)                                                                                                                 |
| `context.go('/products/2')`                                                  | `ProductRoute(id: 2).go(context)` (string paths keep working, and since 0.7.0 `fsp` warns about one that matches no route; under `mount(at: '/shop')` only paths under `/shop` are checked) |
| `errorBuilder`                                                               | `not_found.dart`                                                                                                                                                                            |

- Keep paths identical while migrating: mount at `/` (`AppRoutes.mount()`) once the tree
  holds **every** route at that level, or mount at a prefix and **redirect** the old URLs
  (`redirect.dart` in a folder, or a host `redirect`).
- Reserved names: a segment or query parameter called `data`, `child`, `uri`, `extra`,
  `ref`, `watch`, `read`, `location`, `go`, `push`, ... is refused (the full list is in
  `fespalier/references/binding-rules.md`); rename the parameter when you move a route.
- Commit `lib/app.g.dart`, run `fsp check` in CI, and add the stale-file diff
  (`dart run fespalier gen`, `git diff --exit-code lib/app.g.dart`): `fsp check` alone
  does not catch a stale committed file.

## 4. Tests

`pumpRouter(tester, buildRouter())` from `package:fespalier/testing.dart` works with your
own `GoRouter`, not only `AppRoutes.router()`; build a **new** router per test
(`buildRouter()` is a function for that reason: a router remembers where it went).
