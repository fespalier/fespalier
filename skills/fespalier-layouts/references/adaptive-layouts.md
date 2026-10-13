# Adaptive layouts: `fespalier_adaptive`

Since 0.9.0 (`packages/fespalier_adaptive`). fespalier's core has no adaptive-layout feature and
gains none: **`package:fespalier_adaptive`** draws the `nav.dart` menu (`AppMenu.watch`) as a
`NavigationBar` on a phone, a `NavigationRail` on a tablet and a permanent `NavigationDrawer` on a
wide window, around a layout's body. The destinations, labels, icons, tabs and guards are the
menu's, so the bar is not a second list that drifts from the routes
([`menus-and-breadcrumbs.md`](menus-and-breadcrumbs.md)). It changes **no** generated code (no file
kind, no `fespalier:` key, no `fsp` command), has no third-party dependency, and an app that does not
import it is byte-for-byte what it was. For an app without it, or on 0.8.x, the same thing by hand is
[`adaptive-by-hand.md`](adaptive-by-hand.md).

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_adaptive:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_adaptive
      ref: <the same tag>
```

(A fragment, not a sample: pub resolves the pair only at a release tag. A mismatch fails the way
`fespalier_auth`'s does, see [`auth-package.md`](../../fespalier-guards/references/auth-package.md).)
It needs Dart 3.8 and Flutter 3.32 or newer.

## Two libraries

| Import                                               | What it is                                                                                                                           |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `package:fespalier_adaptive/material.dart`           | `AdaptiveNavScaffold` and `defaultNavIcon`, built on Flutter's Material widgets; **re-exports the model**                            |
| `package:fespalier_adaptive/fespalier_adaptive.dart` | The model, **no Material import**: `AdaptiveNav`, `NavSection`, `NavBreakpoints`, `NavMode`, `WindowSizeClass`, `AdaptiveNavBuilder` |

One import of `material.dart` is enough for a layout that uses the scaffold. An app on
`package:material_ui` imports the model alone and draws it itself (below): Flutter's Material widgets
do not read `material_ui`'s theme.

## A tab layout

`nav.dart` in each tab's folder says what the tab is called and what its icon is. The layout hands
`AppMenu.watch(ref, under: '(tabs)')` and the shell to the scaffold. **Pass `under:` the tab layout's
folder:** it is what gives each entry its `tab`.

```dart
// lib/app/(tabs)/layout.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_adaptive/material.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

const tabs = ['inbox', 'search', 'library'];

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

```dart
// lib/app/(tabs)/inbox/nav.dart
import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

const nav = Nav(
  label: 'Inbox',
  icon: Icons.inbox_outlined,
  selectedIcon: Icons.inbox,
);
```

```dart
// lib/app/(tabs)/inbox/page.dart
import 'package:flutter/material.dart';

class InboxPage extends StatelessWidget {
  const InboxPage({super.key});

  @override
  Widget build(BuildContext context) => const Center(child: Text('Inbox'));
}
```

```dart
// lib/app/(tabs)/search/nav.dart
import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

const nav = Nav(label: 'Search', icon: Icons.search);
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
  Widget build(BuildContext context) => Center(
    child: TextButton(
      onPressed: () => setState(() => _count++),
      child: Text('Search count $_count'),
    ),
  );
}
```

Library is a **heading**: its folder has no `page.dart`, only a `nav.dart` and two pages below. In a
bar or a rail it is one destination, because it is a tab; in the drawer it is the title of a section
over Books and Authors.

```dart
// lib/app/(tabs)/library/nav.dart
import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

const nav = Nav(label: 'Library', icon: Icons.library_books_outlined);
```

```dart
// lib/app/(tabs)/library/books/nav.dart
import 'package:fespalier/nav.dart';

const nav = Nav(label: 'Books');
```

```dart
// lib/app/(tabs)/library/books/page.dart
import 'package:flutter/material.dart';

class BooksPage extends StatelessWidget {
  const BooksPage({super.key});

  @override
  Widget build(BuildContext context) => const Center(child: Text('Books list'));
}
```

```dart
// lib/app/(tabs)/library/authors/nav.dart
import 'package:fespalier/nav.dart';

const nav = Nav(label: 'Authors', order: 1);
```

```dart
// lib/app/(tabs)/library/authors/page.dart
import 'package:flutter/material.dart';

class AuthorsPage extends StatelessWidget {
  const AuthorsPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Authors list'));
}
```

(Without the `nav.dart` of Books and Authors the Library heading has nothing below it and the menu
drops it.) `examples/tabs` is this layout with six `nav.dart` files, a nested tab layout in Library, a
`container` that cross-fades, and tests that resize the window.

## A plain layout

A layout that takes `child` passes `child:` instead of `shell:`; **exactly one of the two** (an
assertion otherwise). Without a shell no entry switches tabs, so every tap is `item.go(context)`, and
the selected destination is the page's.

```dart
// lib/app/(shop)/layout.dart
import 'package:fespalier_adaptive/material.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class ShopLayout extends StatelessWidget {
  const ShopLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AdaptiveNavScaffold(
    child: child,
    menu: (ref) => AppMenu.watch(ref, under: '(shop)'),
    breakpoints: NavBreakpoints.noDrawer,
  );
}
```

```dart
// lib/app/(shop)/catalog/nav.dart
import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

const nav = Nav(label: 'Catalog', icon: Icons.storefront_outlined);
```

```dart
// lib/app/(shop)/catalog/page.dart
import 'package:flutter/material.dart';

class CatalogPage extends StatelessWidget {
  const CatalogPage({super.key});

  @override
  Widget build(BuildContext context) => const Center(child: Text('Catalog'));
}
```

```dart
// lib/app/(shop)/cart/nav.dart
import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

const nav = Nav(label: 'Cart', icon: Icons.shopping_cart_outlined, order: 1);
```

```dart
// lib/app/(shop)/cart/page.dart
import 'package:flutter/material.dart';

class CartPage extends StatelessWidget {
  const CartPage({super.key});

  @override
  Widget build(BuildContext context) => const Center(child: Text('Cart'));
}
```

## What it shows, and when

| Window width | Component                                               | `NavMode` |
| ------------ | ------------------------------------------------------- | --------- |
| under 600    | `NavigationBar` at the bottom                           | `bar`     |
| 600 to 1199  | `NavigationRail` at the start, every label shown        | `rail`    |
| 1200 or more | a permanent `NavigationDrawer`, with the nested entries | `drawer`  |

- **`NavBreakpoints(rail: 600, drawer: 1200)`** are the defaults (Material 3's compact, medium and
  large size classes; `WindowSizeClass.of(width)` names all five). Each is configurable, or `null` for
  never: `NavBreakpoints.noDrawer`, `NavBreakpoints(rail: 840)`, `NavBreakpoints(rail: null,
drawer: null)` (always a bar). `NavBreakpoints(rail: null)` is a bar, then the drawer from 1200.
  A `drawer` below the `rail` asserts: `NavBreakpoints: drawer is below rail`.
- **The width is the window's** (`MediaQuery.sizeOf(context).width`), not the layout's box. A layout in
  a split view that needs its own box's width builds an `AdaptiveNav` under a `LayoutBuilder`.
- **Which entries.** A bar or a rail lists the top-level entries that go somewhere: an entry with a
  route or, with a shell, an entry that is a `tab` (even a heading); a heading that is not a tab is
  replaced by its children. The drawer lists every entry that goes somewhere, **depth first**: a
  heading is a section title, a route's own children stay in its section, so three levels or more are
  flattened under one level of headings.
- **Which is selected.** With a shell and a menu that knows its tabs: the destination whose `tab` is
  the shell's current index (the drawer: the deepest selected entry with a route). Without `under:`
  no entry has a tab and the entries go by the page. A plain layout: the first selected entry.
- **What a tap does.** An entry with a `tab` (and a shell) is
  `shell.goBranch(tab, initialLocation: tab == shell.currentIndex)`: tapping the current tab goes back
  to its first page, as in the bar of [`docs/layouts.md`](https://github.com/fespalier/fespalier/blob/main/docs/layouts.md#a-bar-a-rail-or-a-drawer-fespalier_adaptive). Any other entry is `item.go(context)`.
- **Guards** are whatever `AppMenu.watch` answers: `NavRefused.hide` entries are absent, `disable`
  ones are listed and off (`NavigationDestination(enabled: false)`, `NavigationRailDestination(disabled:
true)`, `NavigationDrawerDestination(enabled: false)`), `pending` ones are on. The destinations are
  mapped through their tab, so a tap never goes to the wrong page after another entry is hidden. The
  menu runs your guards while the layout is on screen, which is always: keep them cheap.

## The phone's bar is hidden on a page no entry covers

A `NavigationBar` cannot show "nothing selected" (it asserts a selected index), so **the bar is not
built** when no destination is the current tab (a plain layout: none is selected) or there are fewer
than two destinations, and the body is shown alone. A rail and a drawer show the page with nothing
selected, and are also left out below two destinations. In a debug build the first time says it, once
per process:

```text
fespalier_adaptive: no menu entry is the current tab (3) of the tab layout, so the navigation bar is hidden. Give the tab's folder a nav.dart (not inMenu: false), and pass AppMenu.watch(ref, under: <the tab layout's folder>).
```

Fixes: give the tab's folder a `nav.dart` (not `inMenu: false`), put the page below an entry, pass
`under:`, or render the menu yourself with an `AdaptiveNavBuilder`. A guard that hides the entry of the
tab you are on does the same until it navigates away.

## Slots

| Argument                | What it is                                                                                                                        |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `icon:`                 | `(context, item, selected) => Widget` for each destination's icon: wrap `defaultNavIcon(...)` in a `Badge`                        |
| `leading:`, `trailing:` | `(context, nav) => Widget` above and below the rail's or the drawer's destinations (a logo, a button); **not** shown with the bar |
| `floatingActionButton:` | `(context, nav) => Widget?` for the `Scaffold`'s button, asked in every mode: return `null` where the button went into `leading`  |

There is no secondary body and no animation of its own: nested layouts already give list and detail.

## Your own widgets: `AdaptiveNavBuilder`

`AdaptiveNavBuilder(menu:, shell:, breakpoints:, builder: (context, nav) => ...)` hands the model to a
builder. `AdaptiveNav` has `mode`, `width`, `destinations`, `sections` (for the drawer), `selectedIndex`,
`visible`, `enabled(index)` and `select(context, index)`. Use it for Cupertino widgets, `material_ui`,
chips, or a layout that is none of bar, rail and drawer. **Put the body at the same place in the tree in
every mode**, or a tab loses its state when the window is resized.

```dart
// lib/app/(chips)/layout.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_adaptive/fespalier_adaptive.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

const tabs = ['first', 'second'];

class ChipsLayout extends StatelessWidget {
  const ChipsLayout({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => AdaptiveNavBuilder(
    menu: (ref) => AppMenu.watch(ref, under: '(chips)'),
    shell: navigationShell,
    builder: (context, nav) => Column(
      children: [
        Wrap(
          children: [
            for (final (i, item) in nav.destinations.indexed)
              ChoiceChip(
                label: Text(item.label(context)),
                selected: nav.selectedIndex == i,
                onSelected: (_) => nav.select(context, i),
              ),
          ],
        ),
        Expanded(child: navigationShell),
      ],
    ),
  );
}
```

```dart
// lib/app/(chips)/first/nav.dart
import 'package:fespalier/nav.dart';

const nav = Nav(label: 'First');
```

```dart
// lib/app/(chips)/first/page.dart
import 'package:flutter/material.dart';

class FirstPage extends StatelessWidget {
  const FirstPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('first page');
}
```

```dart
// lib/app/(chips)/second/nav.dart
import 'package:fespalier/nav.dart';

const nav = Nav(label: 'Second', order: 1);
```

```dart
// lib/app/(chips)/second/page.dart
import 'package:flutter/material.dart';

class SecondPage extends StatelessWidget {
  const SecondPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('second page');
}
```

`package:fespalier_adaptive/fespalier_adaptive.dart` imports no Material, so this works on
`package:material_ui` too. `material.dart` draws Flutter's Material widgets, which read **Flutter's**
`Theme`, not `material_ui`'s: an app that uses `material_ui`'s `MaterialApp` everywhere renders the model
itself, or copies the one scaffold file with the other import (there is no `material_ui` variant yet: it
needs Flutter 3.47).

## Testing it

Size the window with `tester.view`: **Flutter's default test window is 800 × 600 logical pixels, which
is a rail with the default breakpoints** (and a bar with `rail: 840`, what `examples/tabs` uses so that
its older tests keep a bar). Reset it with `addTearDown(tester.view.reset)`.

```dart
// test/adaptive_test.dart
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';

void resize(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('a bar, a rail or a drawer by width, and a tab keeps its state', (
    tester,
  ) async {
    resize(tester, 400);
    await pumpRouter(tester, AppRoutes.router(initialLocation: '/search'));
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.text('Search count 0'));
    await tester.pump();

    for (final (width, component) in [
      (700.0, NavigationRail),
      (1300.0, NavigationDrawer),
      (400.0, NavigationBar),
    ]) {
      resize(tester, width);
      await tester.pumpAndSettle();
      expect(find.byType(component), findsOneWidget);
      expect(find.text('Search count 1'), findsOneWidget);
    }
  });

  testWidgets('the drawer lists Books and Authors under a Library title', (
    tester,
  ) async {
    resize(tester, 1300);
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/library/authors'),
    );
    final drawer = find.byType(NavigationDrawer);
    expect(find.descendant(of: drawer, matching: find.text('Library')), findsOneWidget);
    await tester.tap(find.descendant(of: drawer, matching: find.text('Books')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/library/books');
  });

  testWidgets('a plain layout is a bar, and a tap goes to the route', (
    tester,
  ) async {
    resize(tester, 400);
    await pumpRouter(tester, AppRoutes.router(initialLocation: '/catalog'));
    final bar = find.byType(NavigationBar);
    await tester.tap(find.descendant(of: bar, matching: find.text('Cart')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/cart');
  });
}
```

`examples/tabs/test/adaptive_test.dart` checks each component against the generated `AppMenu`. A
test of the model alone builds `NavItem`s by hand (`NavItem`, `NavNode` and `Nav` have public `const`
constructors): `AdaptiveNav(menu: items, width: 1300)` needs no widget.

## From `flutter_adaptive_scaffold`

That package is discontinued. The nearest equivalents:

| `flutter_adaptive_scaffold`                                               | `fespalier_adaptive`                                                                                           |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `AdaptiveScaffold(destinations:, selectedIndex:, onSelectedIndexChange:)` | `AdaptiveNavScaffold(menu: (ref) => AppMenu.watch(ref, under: ...), shell: ...)`: destinations from `nav.dart` |
| `Breakpoints.small`, `medium`, `large`                                    | `NavBreakpoints(rail:, drawer:)`, `WindowSizeClass`                                                            |
| `useDrawer`, `drawerBreakpoint`                                           | `NavMode.drawer` from `NavBreakpoints.drawer`                                                                  |
| `body`, `secondaryBody`, `bodyRatio`                                      | the layout's `child` or shell; a second pane is a nested `layout.dart`                                         |
| `AdaptiveLayout` and `SlotLayout`                                         | `AdaptiveNavBuilder`                                                                                           |
| `leadingExtendedNavRail`, `trailingNavRail`                               | `leading`, `trailing`                                                                                          |

## Things to remember

- **The body is a keyed `Expanded` in a `Row`** in every mode, so a tab keeps its state and stack
  across a resize. A custom `AdaptiveNavBuilder` layout has to do the same.
- **The scaffold's Material widgets exist in Flutter 3.32** (fespalier's floor), and it uses none of
  `NavigationDrawer.header` and `footer` (3.35): `leading` and `trailing` are children of the drawer.
- A page outside every entry's folder is not under this layout at all if it is outside the layout's
  folder (it has no bar); a root-navigator page (`navigator.dart`) covers the rail and the drawer as it
  covers a bar.
- **`AdaptiveNav.select` is a navigation**: it goes through the guards, like any `go`.
- **No timer, no listener, no wall clock**: the width is read when the layout builds.
