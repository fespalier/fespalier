# Adaptive layouts

As of v0.4.0. fespalier has **no adaptive-layout feature**: a `layout.dart` is an
ordinary widget that receives `child` or a `StatefulNavigationShell`, so going from
a phone to a tablet or desktop layout is plain Flutter (`MediaQuery`,
`LayoutBuilder`) inside that widget. These two patterns were compiled and tested
against v0.3.0; they are patterns, not API.

## A tab layout: bottom bar on phones, rail on wide screens

The same `navigationShell` goes in either arrangement, and `goBranch` switches
tabs in both.

```dart
// lib/app/(tabs)/layout.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

const tabs = ['home', 'search'];

const _destinations = [
  (Icons.home, 'Home'),
  (Icons.search, 'Search'),
];

class AdaptiveTabsLayout extends StatelessWidget {
  const AdaptiveTabsLayout({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _select(int i) => navigationShell.goBranch(
    i,
    initialLocation: i == navigationShell.currentIndex,
  );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: _select,
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final (icon, label) in _destinations)
                  NavigationRailDestination(
                    icon: Icon(icon),
                    label: Text(label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: navigationShell),
          ],
        ),
      );
    }
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: _select,
        destinations: [
          for (final (icon, label) in _destinations)
            NavigationDestination(icon: Icon(icon), label: label),
        ],
      ),
    );
  }
}
```

```dart
// lib/app/(tabs)/home/page.dart
import 'package:flutter/material.dart';

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('home tab');
}
```

```dart
// lib/app/(tabs)/search/page.dart
import 'package:flutter/material.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  int _count = 0;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => _count++),
    child: Text('search count $_count'),
  );
}
```

- Breakpoints are yours; Material's window size classes put 600 and 840 logical
  pixels as the compact/medium/expanded boundaries.
- Tab pages keep their state when the window is resized across the breakpoint: in
  the sample the counter on the Search tab survives the swap between the bar and
  the rail (tested). That holds with `navigationShell` placed directly as the
  `body` or as an `Expanded` child, as above; test it if you wrap it in anything
  else.
- Switching on `MediaQuery.sizeOf` is enough; use `LayoutBuilder` when the
  breakpoint depends on the space the layout is given rather than the window.
- For a `container` (cross-fades), see `tab-layouts.md`; it composes with this.

## A plain layout: drawer on phones, side list on wide screens

A `layout.dart` that takes `child` can highlight the current destination with the
**route manifest**: `AppManifest.of(GoRouterState.of(context))` is the `RouteInfo`
of the route the layout is showing (`null` in a not-found view).

```dart
// lib/app/(shop)/layout.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class ShopLayout extends StatelessWidget {
  const ShopLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final path = AppManifest.of(GoRouterState.of(context))?.path;
    final nav = Column(
      children: [
        TextButton(
          onPressed: () => const CatalogRoute().go(context),
          child: Text(path == '/catalog' ? '> Catalog' : 'Catalog'),
        ),
        TextButton(
          onPressed: () => const CartRoute().go(context),
          child: Text(path == '/cart' ? '> Cart' : 'Cart'),
        ),
      ],
    );
    if (MediaQuery.sizeOf(context).width >= 840) {
      return Scaffold(
        body: Row(
          children: [
            SizedBox(width: 240, child: nav),
            Expanded(child: child),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(),
      drawer: Drawer(child: nav),
      body: child,
    );
  }
}
```

```dart
// lib/app/(shop)/catalog/page.dart
import 'package:flutter/material.dart';

class CatalogPage extends StatelessWidget {
  const CatalogPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('catalog');
}
```

```dart
// lib/app/(shop)/cart/page.dart
import 'package:flutter/material.dart';

class CartPage extends StatelessWidget {
  const CartPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('cart');
}
```

Each pattern sits in its own group folder, so the two layouts do not wrap each
other.

## Things to remember

- **Pages render below the layout's `Scaffold`**, so a `ListTile`-heavy page can
  trip the ink assertion during page transitions; wrap it in
  `Material(type: MaterialType.transparency, child: ...)` (see
  `fespalier-troubleshooting`).
- `not_found.dart` and routes outside the layout's folder render **without** the
  layout: they need their own `Scaffold`.
- `AppManifest.of(state)` reads `AppRoutes.base`, so it works under
  `AppRoutes.mount(at: '/shop')` and for catch-all routes.
