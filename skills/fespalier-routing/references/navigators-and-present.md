# The root navigator: `navigator.dart` and `present.dart`

As of v0.4.0. A route's **URL** and the **navigator it renders on** are two
decisions. A tab layout puts every route in its folder on a tab's own navigator,
under the navigation bar. These two files put a route on the **root** navigator
(above every layout and tab bar) without moving its URL.

The example below has a tab layout (see `fespalier-layouts`) with a full-screen
edit page, and a sheet with a URL of its own.

```dart
// lib/app/(tabs)/layout.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

const tabs = ['home', 'profile'];

class TabsLayout extends StatelessWidget {
  const TabsLayout({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: navigationShell,
    bottomNavigationBar: NavigationBar(
      selectedIndex: navigationShell.currentIndex,
      onDestinationSelected: (i) => navigationShell.goBranch(
        i,
        initialLocation: i == navigationShell.currentIndex,
      ),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
      ],
    ),
  );
}
```

```dart
// lib/app/(tabs)/home/page.dart
import 'package:flutter/material.dart';

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('overview');
}
```

```dart
// lib/app/(tabs)/profile/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => const EditProfileRoute().push(context),
    child: const Text('Edit'),
  );
}
```

## `navigator.dart`

```dart
// lib/app/(tabs)/profile/edit/navigator.dart
import 'package:fespalier/fespalier.dart';

const navigator = RouteNavigator.root;
```

```dart
// lib/app/(tabs)/profile/edit/page.dart
import 'package:flutter/material.dart';

class EditProfilePage extends StatelessWidget {
  const EditProfilePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Edit profile')),
    body: const Center(child: Text('editing')),
  );
}
```

`/profile/edit` is still **under `/profile`**: a deep link builds the Profile tab
beneath it, back returns to it with its state, and the page covers the whole
screen, tab bar included. The typed route is unchanged
(`EditProfileRoute().push(context)`).

- **Scope.** The declaration applies to its folder's routes and to **every
  folder below it**, the nearest one winning, like `transition.dart`. A
  page-less `(group)` folder can hold one for the routes inside.
- **What `fsp gen` emits:** `parentNavigatorKey: rootNavigatorKey` on the route
  and on all its descendants (go*router puts a route on its enclosing shell's
  navigator unless told otherwise, so a child pushed from the page would land
  \_under* it). The route table marks them `root`.
- **The key is the generated file's.** `AppRoutes.rootNavigatorKey` is a
  `GlobalKey<NavigatorState>` the app can read; `AppRoutes.router(navigatorKey:)`
  uses one you supply; `AppRoutes.mount(at:, navigatorKey:)` takes the **host**
  `GoRouter`'s own key, because a `parentNavigatorKey` must name an ancestor
  navigator. Forgetting it when mounting into your own router is the usual way
  to break these routes.
- **The value is written out.** `fsp` reads the source: a `const navigator` that
  is `RouteNavigator.root` or `RouteNavigator.shell` (an import prefix is fine).
  Anything else is an error (see `fespalier-troubleshooting`).
- **A layout is a navigator of its own.** A `layout.dart` below a root folder
  becomes a `ShellRoute(parentNavigatorKey: rootNavigatorKey, ...)` (or the
  stateful one) and the routes inside it sit on its own navigator. Below a layout
  nothing is inherited; `RouteNavigator.shell` is how a folder says so
  explicitly. **Below a root route with no layout in between, `.shell` is an
  error**: go_router only lets a descendant use the root navigator or one above
  it.
- **A root route cannot be a direct child of a shell.** go_router lifts a route
  out of its shell only from **below another route**, so a root route that is
  the first route of a tab, or sits beside others directly in a layout, is an
  error. Put it below a `page.dart` that stays in the layout (as `edit/` is
  below `profile/`), or move its folder out of the layout's folder.
- To cover the whole screen **without** putting the URL in a tab, just put the
  route **outside** the layout's folder.

## `present.dart`

`present.dart` builds **this route's own `Page`**: a sheet, a dialog, or any
page class the app owns, with a URL (`/photos/share` opens a sheet over
`/photos`, from a link or a deep link). fespalier ships no sheet widget and adds
no scrim, handle or shape: what `present()` returns is used **verbatim**.

```dart
// lib/sheet_page.dart
import 'package:flutter/material.dart';

/// The app's own sheet: a Page that makes a PopupRoute with its own scrim.
class AppSheetPage<T> extends Page<T> {
  const AppSheetPage({super.key, super.restorationId, required this.child});

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) =>
      _SheetRoute<T>(settings: this, child: child);
}

class _SheetRoute<T> extends PopupRoute<T> {
  _SheetRoute({required RouteSettings settings, required this.child})
    : super(settings: settings);

  final Widget child;

  @override
  Color get barrierColor => const Color(0x8A102030);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 250);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Align(
    alignment: Alignment.bottomCenter,
    child: Material(child: SafeArea(top: false, child: child)),
  );
}
```

```dart
// lib/app/photos/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class PhotosPage extends StatelessWidget {
  const PhotosPage({super.key});

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => const ShareRoute().push(context),
    child: const Text('Share'),
  );
}
```

```dart
// lib/app/photos/share/page.dart
import 'package:flutter/material.dart';

class SharePage extends StatelessWidget {
  const SharePage({super.key});

  @override
  Widget build(BuildContext context) => const Text('Share photos');
}
```

```dart
// lib/app/photos/share/present.dart
import 'package:flutter/widgets.dart';
import 'package:my_app/sheet_page.dart';

Page<void> present(LocalKey key, Widget child) =>
    AppSheetPage<void>(key: key, child: child);
```

- It is bound like `transition.dart` (`key`, `child`, `state`).
- **It applies to its own folder only.** A folder below keeps the nearest
  `transition.dart` for its own page.
- **It puts the route on the root navigator**, over a tab bar and any
  `layout.dart`, **and its descendants too** (the `navigator.dart` rules: a child
  of a sheet renders above it, never under it). A `navigator.dart` in the same
  folder overrides that; `RouteNavigator.shell` keeps a sheet inside a tab.
- **It needs a `page.dart`** (a warning and no effect otherwise: `present.dart
builds this folder's page, but there is no page.dart here; it is ignored`).
  For a parent underneath on a deep link, the sheet's folder should sit
  **below** the parent page's folder (`photos/share/` below `photos/`).
- The route table tags it `present` and `root`; the manifest's `presentation`
  is `RoutePresentation.custom` (fespalier cannot know it is a sheet: say so in
  a `meta.dart` if you want to). A `navigator.dart` route is
  `RoutePresentation.root`.
- For a plain dialog, sheet or full-screen dialog you do **not** need
  `present.dart`: `Transitions.dialog`, `Transitions.sheet` and
  `Transitions.fullscreenDialog` in a `transition.dart` do it (see
  `fespalier-layouts`). Reach for `present.dart` when the page class is yours.
