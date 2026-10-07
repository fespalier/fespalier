# fespalier_adaptive

`nav.dart` menus as a navigation bar, a rail or a permanent drawer by window width, for
[fespalier](https://github.com/fespalier/fespalier) (since 0.9.0). `AppMenu.watch` is already the list of a
layout's destinations, with their labels, icons, tabs and guards; this package draws it as a `NavigationBar` on a
phone, a `NavigationRail` on a tablet and a `NavigationDrawer` on a wide window, around the same body, so a tab
keeps its state when the window changes size. It has no third-party dependency, and fespalier itself is
unchanged: no `fsp` change, no `fespalier:` key, and the same `app.g.dart`.

The docs cover it in context:
[A bar, a rail or a drawer](https://github.com/fespalier/fespalier/blob/main/docs/layouts.md#a-bar-a-rail-or-a-drawer-fespalier_adaptive).
This page is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if
they are the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.10.0
  fespalier_adaptive:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_adaptive
      ref: v0.10.0
```

<!-- x-release-please-end -->

Needs Dart 3.8 and Flutter 3.32 or newer.

## Wire it

A `nav.dart` in each tab's folder says what the tab is called and what its icon is ([Menus and breadcrumbs](https://github.com/fespalier/fespalier/blob/main/docs/layouts.md#menus-and-breadcrumbs-navdart)). The tab layout then hands the menu to the scaffold:

```dart
// lib/app/(tabs)/layout.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_adaptive/material.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class TabsLayout extends StatelessWidget {
  const TabsLayout({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => AdaptiveNavScaffold(
    shell: navigationShell,
    menu: (ref) => AppMenu.watch(ref, under: '(tabs)'),
  );
}
```

- A bar under 600 logical pixels, a rail from 600, a drawer from 1200: `NavBreakpoints(rail: 600, drawer: 1200)`,
  each configurable or `null` (never).
- `under:` the tab layout's folder gives each entry its tab. Without it the entries go by the page.
- A plain layout passes `child:` instead of `shell:`.
- **The phone's bar is hidden on a page no menu entry covers**, because a `NavigationBar` cannot show "nothing
  selected" (a debug build says so once). A rail and a drawer show none selected.
- `icon:`, `leading:`, `trailing:` and `floatingActionButton:` are slots; `AdaptiveNavBuilder` hands the model
  (`AdaptiveNav`) to widgets of your own.

`package:fespalier_adaptive/fespalier_adaptive.dart` is the model and imports no Material;
`package:fespalier_adaptive/material.dart` is the scaffold, built on Flutter's Material widgets (Flutter 3.32
has every one it uses), and re-exports the model. An app on `package:material_ui` renders the model itself.

## Test it

Size the window: `tester.view.physicalSize = const Size(1000, 800)`, `tester.view.devicePixelRatio = 1`, and
`addTearDown(tester.view.reset)`. Flutter's default test window is 800 × 600 logical pixels, which is a rail with
the default breakpoints. `examples/tabs/test/adaptive_test.dart` in the repository checks each component by width
and that a tab keeps its state across a resize.
