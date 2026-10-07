# Layouts

## Tab layouts

```dart
// lib/app/(tabs)/layout.dart
const tabs = ['(home)', 'search', 'profile'];

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
          destinations: [ … ],
        ),
      );
}
```

A `layout.dart` that asks for a `StatefulNavigationShell` (named `navigationShell` or `shell`, or by that
type) instead of a `Widget child` is a tab layout. It becomes a go_router
`StatefulShellRoute.indexedStack` (or, with a [`container`](#tab-layouts), your own
`navigatorContainerBuilder`), so each tab keeps its own navigation stack and state while you look at another
one. Asking for both a child and a shell is an error. A tab layout can also ask for segments and query
parameters like any other layout.

**Which tabs.** A tab (a branch) is the layout folder's own `page.dart`, if it has one, then each direct
subfolder that holds routes: a static or dynamic folder, or a `(group)`. Whatever is below a subfolder
(nested pages, data, guards, transitions, more layouts) stays inside its tab.

- Branches follow folder order, which is alphabetical, unless `tabs` lists them.
- `tabs` is a top-level `const` list of string literals naming each folder as written, and `'.'` for the
  folder's own page. It must list every branch exactly once: an unknown, missing or repeated name is an
  error. Name any other list of destinations something else.
- A tab layout folder without its own `page.dart` has no route at its own path: link to one of its tabs'
  routes instead.

**Outside the tabs.** Routes outside the layout's folder are in no tab, so they cover the whole screen: in
`examples/tabs`, `/settings` has no navigation bar. To cover the screen while the URL stays in a tab
(`/profile/edit`), use [`navigator.dart`](navigation.md#the-root-navigator-navigatordart).

**Two errors.** go_router opens a tab on its first route, which can't have a `:segment` in its own path. So a
tab made only of dynamic routes, or a tab layout placed directly in a `$folder`, is an error. Put the layout
in a `(group)` below that folder instead (a tab's `initialLocation`, below, also fixes the first case).

Since 0.9.0, `package:fespalier_adaptive` can draw the bar from the menu, as a bar, a rail or a drawer by
window width: see [A bar, a rail or a drawer](#a-bar-a-rail-or-a-drawer-fespalier_adaptive).

**Nested tab layouts.** A tab layout can sit inside a tab of another one: put a `layout.dart` that takes a
`StatefulNavigationShell` in a folder that is a branch of the outer layout.

```text
lib/app/(tabs)/
  layout.dart              const tabs = ['(home)', 'search', 'library']; takes a shell
  (home)/page.dart
  search/page.dart
  library/                 the third outer tab...
    layout.dart            ...is itself a tab layout: const tabs = ['books', 'authors'];
    books/page.dart          /library/books
    authors/page.dart        /library/authors
```

Each layout has its own `tabs` list, stacks and `StatefulNavigationShell`, and the outer layout keeps the
whole inner one alive, so an inner tab's state survives switching outer tabs. The rules above apply at each
level. `library/` has no page of its own here, so its inner layout is what the outer tab shows; give it a
`page.dart` and that page becomes the inner layout's first tab. `examples/tabs` builds Library this way, and
its tests check that a counter in an inner tab survives switching inner and outer tabs.

**Tab options.** A tab layout can set go_router's `StatefulShellBranch` options per tab in a top-level
`const tabOptions` map, next to `tabs`. Keys are the tab names `tabs` uses (`'.'` for the layout's own page);
each value is a `TabOptions` from `package:fespalier/fespalier.dart`:

```dart
const tabOptions = {
  'search': TabOptions(preload: true),
  'profile': TabOptions(initialLocation: '/profile/edit'),
};
```

- `preload: true` builds the tab as soon as the layout first shows, instead of on its first visit.
- `initialLocation` is where the tab opens the first time, and where tapping its current tab goes with
  `goBranch(i, initialLocation: true)`, instead of the tab's first route. It is an app location such as
  `/profile/edit` (with `?query` if you like), written as a string literal, and must be a route inside that
  tab; `fsp` checks that (dynamic routes match any value: `/items/1` for `items/$id`). It lets a tab that has
  only dynamic routes work, since go_router then needs no first route without a `:segment`. When mounted with
  `AppRoutes.mount(at: '/x')`, the mount point is added for you.

Like `tabs`, `tabOptions` is read from the source, not run: a map literal with string-literal keys and
`TabOptions(...)` values with `true`/`false` and string-literal arguments. Unknown tabs, repeated tabs,
unknown options and other values are errors that point at the offending entry. List only the tabs that need
options.

**Container.** By default the tabs' navigators sit in an `IndexedStack`. Export a top-level `container`
function from the tab layout to arrange them yourself, say to cross-fade or slide between tabs:

```dart
// lib/app/(tabs)/layout.dart
Widget container(BuildContext context, StatefulNavigationShell shell, List<Widget> children) =>
    CrossFadeContainer(currentIndex: shell.currentIndex, children: children);
```

The generated route is then `StatefulShellRoute(navigatorContainerBuilder: _i1.container, …)` instead of
`.indexedStack(…)`; a layout without `container` still generates `.indexedStack(…)`.

- The three parameters are positional and their **types are fixed** (`BuildContext`,
  `StatefulNavigationShell`, `List<Widget>`; the names are yours). A wrong type, a missing or an extra
  parameter, or a return type that isn't `Widget` is an error at the parameter.
- `children` holds one navigator per tab, in tab order. Keep them all in the tree (`Offstage`, `Opacity` or a
  `Stack`, as `IndexedStack` does) or the tabs lose their state.
- Wrap the ones you don't show in `TickerMode(enabled: false)`, as go_router's container does: that is how a
  [shared element](#shared-elements-heroes) (since 0.8.1) knows its tab is hidden.
- A `container` in a layout that isn't a tab layout is ignored with a warning.

`examples/tabs` cross-fades, and its tests check that a tab's state survives.

## Menus and breadcrumbs: `nav.dart`

Since 0.8.1. A drawer, a bottom bar, a tab bar and a breadcrumb row all list the same thing: the folders of
the app and where they go. A `nav.dart` in a folder says how that folder shows up, and `fsp gen` writes
`AppMenu` at the end of `lib/app.g.dart` from all of them, so a menu is not a second list to keep in step
with the routes. An app with no `nav.dart` generates the same file as without the feature.

```dart
// lib/app/products/nav.dart
import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

const nav = Nav(
  label: 'Products', // without a BuildContext (`fsp routes`, tests), and the fallback
  icon: Icons.storefront_outlined,
  selectedIcon: Icons.storefront,
  order: 1, // siblings sort by `order`, then by their place as a tab, then by folder name
);

/// Optional: the label shown, localized. It can ask for the segments of its folder and above.
String label(BuildContext context) => AppLocalizations.of(context)!.products;
```

`Nav` and `NavItem` live in `package:fespalier/nav.dart`, not in the barrel, so they collide with nothing you
have. `nav` must be a `const` `Nav(...)` call and `order` a whole-number literal: `fsp` reads both from the
source. A folder with a `page.dart` or `redirect.dart` is an entry that goes there; a folder without one is a
**heading** that holds the entries of the folders below it, and is left out (with a warning) when there are
none.

```dart
// lib/app/orders/$id/nav.dart: a breadcrumb, not a menu entry
const nav = Nav(label: 'Order', inMenu: false);
String label(BuildContext context, {required int id}) => 'Order #$id';
```

**Reading it.** Call these in `build`, in a layout or a page:

- `AppMenu.watch(ref)` returns the entries at the current location, nested as the folders are, as `NavItem`s.
- `AppMenu.breadcrumbs(ref)` returns the entries from the top down to the page.

They read the router's location, so the widget rebuilds when it changes (above the router, in
`MaterialApp.builder`, there is none).

```dart
class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    children: [
      for (final item in AppMenu.watch(ref))
        ListTile(
          leading: Icon(item.icon), // selectedIcon while selected
          title: Text(item.label(context)),
          selected: item.selected,
          enabled: item.enabled, // false: its guards refuse it, with `NavRefused.disable`
          onTap: () => item.go(context),
        ),
    ],
  );
}

// a tab bar: AppMenu.watch(ref, under: '(tabs)') lists the entries at or below that folder,
// and each one's `tab` is its index in the tab layout of that folder
final tabs = AppMenu.watch(ref, under: '(tabs)');
NavigationBar(
  selectedIndex: navigationShell.currentIndex,
  onDestinationSelected: (i) => navigationShell.goBranch(i),
  destinations: [for (final t in tabs) NavigationDestination(icon: Icon(t.icon), label: t.label(context))],
);

// breadcrumbs
Text(AppMenu.breadcrumbs(ref).map((c) => c.label(context)).join(' › '));
```

**Which entries, and in what order.**

- The app folder's own `nav.dart`, and the one of a tab layout's own `page.dart`, are _flat_: they sit beside
  the entries below them instead of holding them, and are selected on their own route only. Any other entry
  holds the entries of the folders below it (`children`).
- Siblings sort by `order`, then by their index as a tab (see `NavItem.tab`), then by folder name.
- `under:` takes a folder (`'(tabs)'`, `r'teams/$teamId'`, `''` for everything) and returns the topmost
  entries at or below it. It is an assertion in debug when no `nav.dart` is there.
- An entry whose folder has segments (`orders/$id`) is listed only at a location that has them (`/orders/7`,
  `/orders/7/refund`): its route is built from that location. Elsewhere it is left out, with the entries
  below it.
- `inMenu: false` leaves an entry out of `watch`, and its children with it; the breadcrumbs keep it.
- A selected entry is the one of the page or of a folder above it.

**Guards.** An entry is shown only if the guards that would run for a navigation to it let it through: those
of its folder and the ones above it, asked with the entry's own location. The entry's `whenRefused` says what
the menu does with a refused one: `NavRefused.hide` (the default) leaves it out, `disable` lists it with `enabled == false`, and `show` lists it without asking its guards at all.

- A guard that answers at once (the usual `ref.watch(session) ? null : '/login'`) is in the **first frame** of
  the widget that asks. A `Ref` guard is followed: when what it `ref.watch`es changes, the entry changes in
  the next frame, with no navigation.
- A guard that returns a `Future` makes the entry **pending**: listed and enabled
  (`NavItem.access == NavAccess.pending`) until the answer is in, then allowed or refused. Nothing waits for
  it, and no timer is used. A guard that throws is reported (`FlutterError.reportError`) and the entry stays
  pending.
- A guard written with `ProviderContainer c` (the older form) is called with the `Ref`'s container and read
  once when the menu asks, as a navigation does: the menu does not follow it.
- The menu **runs your guards**, each once per entry while a menu with it is on screen (and again when what
  they watch changes), so a guard has to be cheap and free of side effects. The answers are kept in one
  provider per entry that goes with the widgets that watch it: a menu that leaves the screen lets go of
  everything its guards watch.

**Labels.** `label()` gets the `BuildContext`, so it can read `AppLocalizations`, the locale or a
provider-backed setting, and the segments it names (`required int id`), typed like any other file in the
folder. It is not given data: a breadcrumb that shows a product's name reads the product in the widget
(`ProductRoute.watch(ref, id: item.params['id'] as int)`).

Not built: more than one menu per app (use `under:` and `inMenu`), labels from `data.dart`.
`fsp new orders --nav` writes a `nav.dart` for a folder, and `fsp routes --json` has a `nav` key on the routes
whose folder has one (`file`, `label` when it is a string literal, `order`). `examples/features` has a menu, a
team sub-menu and breadcrumbs, with tests for each guard case.

### A bar, a rail or a drawer: fespalier_adaptive

Since 0.9.0. The menu is one list; what changes with the screen is the component that shows it.
`package:fespalier_adaptive` draws `AppMenu.watch` around a layout's body as:

- a `NavigationBar` on a phone,
- a `NavigationRail` on a tablet,
- a permanent `NavigationDrawer` on a wide window.

The bar is no longer a second list of destinations that can drift from the routes, and guards hide or
disable entries as they do in any menu. It is a package of its own: no `fsp` change, no `fespalier:` key,
the same `app.g.dart`, no third-party dependency, and an app that does not depend on it is unchanged. Add it
next to fespalier, with the same `url` and the same `ref`
([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.9.1
  fespalier_adaptive:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_adaptive
      ref: v0.9.1
```

<!-- x-release-please-end -->

It needs Dart 3.8 and Flutter 3.32 or newer. The tab layout of [Tab layouts](#tab-layouts), with a `nav.dart`
in each tab's folder for its label and icon, becomes:

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
    // under: the tab layout's folder, so each entry knows which tab it is
    menu: (ref) => AppMenu.watch(ref, under: '(tabs)'),
    breakpoints: const NavBreakpoints(rail: 840),
  );
}
```

`tabs`, `tabOptions` and `container` stay as they are. A plain layout (one that takes a `Widget child`)
passes `child: child` instead of `shell:`, and exactly one of the two is asserted. `examples/tabs` is this,
with its six `nav.dart` files and tests that resize the window.

**Breakpoints.** The component follows the window's width in logical pixels
(`MediaQuery.sizeOf(context).width`):

| Width          | Component                                               | `NavMode` |
| -------------- | ------------------------------------------------------- | --------- |
| under 600      | `NavigationBar` at the bottom                           | `bar`     |
| 600 to 1199    | `NavigationRail` at the start, every label shown        | `rail`    |
| 1200 and wider | a permanent `NavigationDrawer`, with the nested entries | `drawer`  |

Those are `NavBreakpoints(rail: 600, drawer: 1200)`, Material 3's compact, medium and large window size
classes (`WindowSizeClass.of(width)` names all five). Both are configurable, and `null` means never:
`NavBreakpoints.noDrawer`, or `NavBreakpoints(rail: 840)`, which `examples/tabs` uses so that a bar serves up
to small tablets in portrait (and so that Flutter's default 800 × 600 test window keeps the bar). A `drawer`
below the `rail` is an assertion. A layout inside a split view that needs the width of its own box builds an
`AdaptiveNav` itself, under a `LayoutBuilder` (see _Your own widgets_, below).

**Which entries.**

- The bar and the rail list the top-level entries that go somewhere: an entry with a route or, in a tab
  layout, an entry that is a tab, even a heading. Library in `examples/tabs` is a folder with no `page.dart`,
  and it is the fourth destination. A heading that is not a tab is replaced by the entries below it.
- The drawer lists every entry that goes somewhere, depth first. A heading is the title of a section over the
  entries below it (Books and Authors under Library), and a route's own children stay in its section, so a
  tree of three levels or more is flattened under one level of headings.
- **Pass `under:` the tab layout's folder.** That is what gives each entry its `tab`: the selected
  destination is the one whose `tab` is the shell's current index (the drawer's: the deepest selected entry
  with a route), tapping a tab is `goBranch`, and tapping the current one goes back to its first page. Any
  other entry is `item.go(context)`. Without `under:` no entry has a tab, so the entries go by the page: a
  heading is no destination and the current tab does not reset.
- **Guards** are whatever `AppMenu.watch` answers. A `NavRefused.hide` entry is absent, and the destinations
  are mapped through their tab, so a tap never lands on the wrong page after another entry went away. A
  `NavRefused.disable` entry is listed and turned off, and a `pending` one is on. The menu runs your guards
  while the layout is on screen, which is always: keep them cheap, as [Guards](guards.md) says.

**The phone's bar is hidden on a page no entry covers.** A `NavigationBar` cannot show "nothing selected": it
asserts a selected index. When no destination is the current tab (a plain layout: none is selected), or there
are fewer than two destinations, the bar is not built and the body is shown alone. A debug build says so once:

```text
fespalier_adaptive: no menu entry is the current tab (3) of the tab layout, so the navigation bar is hidden. Give the tab's folder a nav.dart (not inMenu: false), and pass AppMenu.watch(ref, under: <the tab layout's folder>).
```

Fix it in the layout's source: give the page's folder (the tab's) a `nav.dart`, put the page below an entry,
or render the menu yourself with an `AdaptiveNavBuilder`. A rail and a drawer have no such limit: they show
the page with no destination selected.

**State.** The body (the shell or the child) sits at one place in the tree in every mode, so a tab keeps its
stack and state when the window is resized or a tablet is rotated. No timer, no listener: the width is read
when the layout builds.

**Slots.** `icon:` builds each destination's icon (wrap it in a `Badge`). `leading:` and `trailing:` go above
and below the destinations of the rail and the drawer (a logo, a button) and are not shown with the bar.
`floatingActionButton:` is the scaffold's, asked in every mode: return `null` where the button went into
`leading`.

```dart
AdaptiveNavScaffold(
  shell: navigationShell,
  menu: (ref) => AppMenu.watch(ref, under: '(tabs)'),
  icon: (context, item, selected) => Badge(
    isLabelVisible: item.folder.endsWith('inbox'),
    child: defaultNavIcon(context, item, selected),
  ),
  leading: (context, nav) => const FlutterLogo(),
)
```

**Your own widgets.** `AdaptiveNavBuilder` hands the model, an `AdaptiveNav` (`destinations`, `sections`,
`selectedIndex`, `visible`, `enabled(i)` and `select(context, i)`), to a builder you write: chips, Cupertino
widgets, or `package:material_ui`'s. The Library layout of `examples/tabs` draws its two inner tabs as chips
this way.

```dart
AdaptiveNavBuilder(
  menu: (ref) => AppMenu.watch(ref, under: '(tabs)/library'),
  shell: navigationShell,
  builder: (context, nav) => Row(children: [
    for (final (i, item) in nav.destinations.indexed)
      ChoiceChip(
        label: Text(item.label(context)),
        selected: nav.selectedIndex == i,
        onSelected: (_) => nav.select(context, i),
      ),
  ]),
)
```

**Two libraries.**

- `package:fespalier_adaptive/fespalier_adaptive.dart` (the model, `NavBreakpoints`, `AdaptiveNavBuilder`)
  imports no Material.
- `package:fespalier_adaptive/material.dart` (the scaffold, and a re-export of the model) draws Flutter's
  Material widgets, which do not read `package:material_ui`'s theme (see
  [go_router 18 and Material](getting-started.md#go_router-18-and-material)). An app on `material_ui`
  renders the model itself, or copies the scaffold (one file) with the other import.
- The scaffold builds on Flutter 3.32: it leaves out `NavigationDrawer.header` and `footer` (3.35), and puts
  `leading` and `trailing` among the drawer's children.

**Testing.** A test sizes the window with `tester.view.physicalSize` (and `devicePixelRatio = 1`, and
`addTearDown(tester.view.reset)`). Flutter's default test window is 800 × 600 logical pixels, which is a rail
with the default breakpoints and a bar with `rail: 840`. `examples/tabs/test/adaptive_test.dart` checks each
component by width and that a tab keeps its state across a resize.

## Transitions

```dart
// lib/app/transition.dart: every route fades in, unless a folder overrides it
Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);
```

`transition.dart` says how a route animates in. It applies to its folder's route and every route below it,
and the nearest one wins. A `transition.dart` at the root is the app-wide default; any folder or `(group)`
folder can override it for its own routes.

The function returns a `Page`, and takes the page's key as `LocalKey key`, the page itself as `Widget child`,
and optionally `GoRouterState state`. `Transitions` has ready-made ones: `fade`, `slide`, `none`, `material`,
`cupertino`, and `dialog`, `sheet` and `fullscreenDialog` (below). Every one but `dialog` and `sheet` takes
`heroes:` ([shared elements](#shared-elements-heroes), since 0.8.1).

The `key` is go_router's `state.pageKey` (the path template) for a route's page, unless the route
[remounts](navigation.md#remounting-a-page-remount) (since 0.6.0): then it is a key that changes with the
URL, and a change makes the page a new one, which this transition plays for.

**A layout's shell is a page too.** The `ShellRoute` a `layout.dart` makes, and a tab layout's
`StatefulShellRoute`, take the nearest `transition.dart` (the layout folder's own included) as their
`pageBuilder`. So a layout moves like any other page when a route on the
[root navigator](navigation.md#the-root-navigator-navigatordart) opens over it.

- The shell's page key is `ValueKey<String>('layout:(tabs)/')`, made from the layout's folder. It is the same
  on every launch (its restoration id, see [State restoration](#state-restoration)) and while you switch
  routes inside the shell, so **only entering or leaving the shell animates it**, not going from one page of
  the layout to another.
- A layout with no `transition.dart` above it keeps `layoutPage(…)`.
- `fsp init` writes a root `transition.dart`, so most apps' shells now have a `pageBuilder` of their
  transition's making: regenerate and check your layouts.

A `transition()` that needs to tell a shell from a route (to wrap a route's page in something its shell
shouldn't get) can take `bool shell` (or `isShell`): `true` for a layout's shell, `false` for a route's page.
It is the only extra parameter besides `key`, `child` and `state`.

**Page names** (since 0.9.0). Each `pageBuilder:` the generated file writes is wrapped in
`namedPage('/products/:id', () => ...)`. That covers a route with a `transition.dart` or a `present.dart`, a
[`remount`](navigation.md#remounting-a-page-remount) route, and a layout's shell. The pages `Transitions.*`,
`layoutPage` and `remountPage` build while it runs are named by the route's pattern
(`RouteSettings.name`).

- A `NavigatorObserver` (Sentry's, Firebase Analytics', PostHog's) sees `/products/:id` instead of `null` (a
  `remount` page used to be `:id`).
- A layout's shell is named by its section's pattern: `/` for a root layout or a `(tabs)/` group, `/shop` for
  `shop/layout.dart`. go_router forwards a shell navigator's pushes to the root navigator's observers, so an
  observer given to `AppRoutes.router(observers: ...)` sees the pages inside a shell too.
- A route with no `pageBuilder:` (a bare `builder:`) is go_router's own page, named
  `state.name ?? state.path`, and unchanged: a root `transition.dart`, which `fsp init` writes, names every
  page.
- A `Page` of your own in a `transition.dart` reads the name from `Transitions.pageName` (null outside the
  generated page builders): `MaterialPage(key: key, name: Transitions.pageName, child: child)`.
- Keys, restoration ids, transitions and heroes are the same. `namedPage` runs its builder once,
  synchronously, and brings the previous name back when it returns or throws.

**Dialogs and sheets.** `Transitions.dialog`, `Transitions.sheet` and `Transitions.fullscreenDialog` make a
route open over the previous page instead of replacing it. The page's widget is what shows up:

- `dialog`: the dialog itself (an `AlertDialog`, a `Dialog` or your own card, as in `showDialog`'s builder).
- `sheet`: the sheet's content (wrapped in a `Material`).
- `fullscreenDialog`: a Material page that slides up, with a close button in its `AppBar`.

```dart
// lib/app/photos/$id/transition.dart: /photos/:id is a dialog over /photos
Page<void> transition(LocalKey key, Widget child) => Transitions.dialog(key, child);

// lib/app/photos/sort/transition.dart
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.sheet(key, child, showDragHandle: true);
```

They are real Navigator routes (a `DialogRoute` and a `ModalBottomSheetRoute` made by the page), so
everything works as it does for `showDialog`: `context.pop()`, the back button and the barrier pop the route,
and `dialog` and `sheet` take options such as `barrierDismissible`, `isScrollControlled` and `enableDrag`. A
few things to know:

- **Put the route below a page.** The page underneath stays built and visible. go_router builds a deep link's
  stack from the parents that have a page, so with `photos/page.dart` above `photos/$id/`, `/photos/7` opens
  the dialog over `/photos`. Without a parent page, the dialog opens over an empty screen. (A route with
  [`nest = false`](routing.md#a-sibling-with-a-compound-path) is not below the page of the folder above it,
  so it opens over the page above that one.)
- **They cover their own navigator only.** Inside a tab, a dialog covers that tab's navigator, not the tab
  layout's navigation bar; the same goes for a `layout.dart`'s body. Put the route outside the layout's
  folder to cover the whole screen, or give it a [`present.dart`](navigation.md#presentdart-a-page-of-your-own)
  (which puts it on the root navigator) or a [`navigator.dart`](navigation.md#the-root-navigator-navigatordart)
  beside its `transition.dart`.
- **They need `MaterialLocalizations`,** like `showDialog` and `showModalBottomSheet`: a `MaterialApp` (or a
  `Localizations` with the Material delegate) above the router.
- The route's `transition.dart` also covers routes below it, so give a dialog route its own folder.

Routes with no `transition.dart` above them keep go_router's default for your app type: the platform
transition under a Material or Cupertino app, none otherwise (see the go_router 18 note in
[Getting started](getting-started.md#go_router-18-and-material)). Scaffold one with `fsp new … --transition`.

### Shared elements (heroes)

Since 0.8.1, a shared element that flies from a list to a detail page is one line on each side:
`route.hero(name, child: ...)` on every typed route.

```dart
// lib/app/products/page.dart: in the row of each product
leading: ProductRoute(id: p.id).hero('avatar', child: CircleAvatar(child: Text(p.name[0]))),

// lib/app/products/$id/page.dart
ProductRoute(id: product.id).hero('avatar', child: CircleAvatar(radius: 40, child: Text(product.name[0]))),
```

- The tag is the route's path (its location without the query, mount prefix included) and the name, so both
  sides agree when they name the same route and the same element. `ProductsRoute()` and
  `ProductsRoute(sort: Sort.name)` share theirs.
- A name is any object: an app's own `enum` keeps it typo-proof.
- `hero` is an extension (`RouteHeroes`) of the typed routes, not a member, so a route with a query parameter
  called `hero` still compiles (it shadows the extension; `RouteHeroes(route).hero(...)` still reaches it).
- `route.heroTag(name)` is the tag alone (a `RouteHeroTag`), for a `Hero` of your own.
- Nothing is generated: `app.g.dart` doesn't change.

`hero` builds a `RouteHero`, which is Flutter's `Hero` with one difference: it stays out of flights while its
tab is not shown (`TickerMode` is off for it, as go*router's tab container and `examples/tabs`' set it on the
tabs they hide). Two tabs can then show the same tag, and a route on the
[root navigator](navigation.md#the-root-navigator-navigatordart) that opens over the tab bar flies from the
tab that is shown. With a plain `Hero`, that is Flutter's *"There are multiple heroes that share the same tag
within a subtree"\_ assertion in debug.

**The flight style** is declared in `transition.dart`: `Transitions.fade`, `slide`, `none`, `material`,
`cupertino` and `fullscreenDialog` take `heroes:`, a `Heroes` with three options.

```dart
// lib/app/transition.dart: iOS-style pages, and heroes that follow the back swipe
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.cupertino(key, child, heroes: const Heroes(onBackGesture: true));
```

| `Heroes` option | What it does                                                                                                          |
| --------------- | --------------------------------------------------------------------------------------------------------------------- |
| `onBackGesture` | heroes also fly while the user swipes back (`Hero.transitionOnUserGestures`); `false` by default                      |
| `path`          | `HeroFlightPath.platform` (the navigator's: an arc in a Material app, a line in a Cupertino one), `arc` or `straight` |
| `shuttle`       | what is shown while flying (`Hero.flightShuttleBuilder`); the destination's child by default                          |

`heroes:` wraps the page's child in a `RouteHeroScope`, which every `RouteHero` below it reads.

- The nearest `transition.dart` that passes `heroes:` decides; one that doesn't leaves the tree as it was
  before 0.8.1.
- A layout's shell takes it too, so the scope covers every page inside the layout.
- A `RouteHero`'s own `onBackGesture:`, `path:` and `shuttle:` override it for that hero.
- A [`present.dart`](navigation.md#presentdart-a-page-of-your-own) page, or a `Page` of your own, wraps its
  child in a `RouteHeroScope(heroes: ..., child: ...)` itself.

What flies, and what doesn't:

| Situation                                                                                                                                                 | What happens                                                                                                                                                                                                              |
| --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| List to detail in one navigator (the app, a `layout.dart`, a tab)                                                                                         | flies on push and on pop                                                                                                                                                                                                  |
| A route on the root navigator (`navigator.dart`, a `present.dart` that builds a `PageRoute`, a route outside the layout) over a page in a shell or tab    | flies from the tab that is shown                                                                                                                                                                                          |
| A hero in a tab that is not shown                                                                                                                         | out of flights. A custom tab [`container`](#tab-layouts) must wrap the tabs it doesn't show in `TickerMode(enabled: false)`, as go_router's and `examples/tabs`' do                                                       |
| Switching tabs (`goBranch`)                                                                                                                               | nothing flies: no route is pushed, the `container` is the tab animation                                                                                                                                                   |
| `Transitions.dialog`, `sheet`, or a `present.dart` that builds a `PopupRoute`                                                                             | nothing flies: Flutter flies heroes between page routes only. Use `fullscreenDialog`, `material` or a `PageRoute`                                                                                                         |
| A [remounted](navigation.md#remounting-a-page-remount) page                                                                                               | it is a new route: a tag made from the segments differs between the two pages, so nothing flies, while a tag that is the same on both pages flies                                                                         |
| A page with [`data.dart`](data.md#datadart-a-function-a-selector-or-a-provider) or a [deferred](navigation.md#deferred-routes-a-pages-code-on-demand) one | flies when the page is in the destination's first frame: [preload it](navigation.md#preloading-the-data-behind-a-link) (`RouteLink(preload: Preload.intent)`, `route.preload`), or `loading.dart` shows and nothing flies |
| A back swipe or predictive back                                                                                                                           | flies only with `onBackGesture: true` on **both** pages (Flutter checks each side): set it in the root `transition.dart`                                                                                                  |
| A [`ResponsiveImage`](responsive-images.md#images-in-heroes) hero                                                                                         | without `ResponsiveImage.flightShuttle` the shuttle measures itself at every size of the flight and asks for a URL; with it (`route.imageHero`, since 0.9.0) it shows what is loaded and asks for nothing                 |
| One tag twice on one page                                                                                                                                 | Flutter's assertion: give the second one another name, or wrap it in `HeroMode(enabled: false)`                                                                                                                           |

A hero name declared in a deferred `page.dart` would make the list page import that page and load it eagerly
(and the [deferred](navigation.md#deferred-routes-a-pages-code-on-demand) type rule applies to enums), so keep
an enum of names in a file of its own. `examples/shop` (the product avatar, list to detail) and
`examples/tabs` (the profile avatar, over the tab bar) use it.

## State restoration

Pass a scope id to the router, and give the app one too. Flutter then saves what the user was doing when the
OS kills the app, and puts it back on the next launch:

```dart
MaterialApp.router(
  restorationScopeId: 'app',
  routerConfig: AppRoutes.router(restorationScopeId: 'router'),
);
```

Without the ids nothing changes. With them, the location comes back (also for routes deep in a stack), and so
does everything below:

- **Tabs.** Each tab layout and each of its tabs gets a stable `restorationScopeId` from its folder
  (`layout:(tabs)/`, `tab:(tabs)/search`; `.` is the layout's own page), so the selected tab _and_ the stack
  of every tab you visited are restored, nested tab layouts included.
- **Layouts.** A plain layout's Navigator gets one too (`layout:(account)/`).
- **Pages.** What a page keeps in a `RestorationMixin` (a `RestorableInt` for a form field or a scroll
  offset) comes back if the page has a `restorationId`.
  - go_router's own pages have one; the ones `Transitions.*` build take it from the page key.
  - A `Page` you build in a `transition.dart` should pass `restorationId: key.value` too, or its state won't
    be restored.
  - A page that [remounts](navigation.md#remounting-a-page-remount) has the segments or the location in its
    key, so each URL it starts again at restores its own state.
- **`extra`.** An object passed with `context.go(…, extra: …)` is saved with the location if the router has an
  [`extraCodec`](navigation.md#restoring-extra-on-the-web) that knows its type (the same one the browser's
  history uses on the web).

**Why layouts need generated pages.** go_router keys the page of a `ShellRoute` or `StatefulShellRoute` by the
route object's `hashCode` and uses it as the restoration id. That changes on every launch, so nothing under
it can be found again. The generated router builds these pages with an id from the layout's folder instead:

- with a [`transition.dart`](#transitions) above the layout: its `Page` under a `ValueKey` made of that id
  (the `Transitions.*` pages take their restoration id from the key);
- otherwise `layoutPage(...)`: a Material page (a Cupertino one inside a `CupertinoApp`) with the id, under
  the same `ValueKey` (since 0.5.0; go_router's key, the route object's hash code, made a router built again
  by a hot reload or a test replace the layout and lose its state).

Ids come from folder names, so renaming a folder drops what was saved under the old one, once.
`examples/tabs/test/restoration_test.dart` restores the selected tab, a background tab's stack, a page's
`RestorableInt` and a page's `extra` with `tester.restartAndRestore()`. Build the router in a `State`, not a
`final`, in such a test: a router remembers where it went.

## Scroll restoration

Since 0.8.1. Flutter builds a page from nothing when the browser's back or forward button brings it back, so
a long list starts at the top again. `scroll_restoration: true` in the `fespalier:` section of `pubspec.yaml`
(off by default) gives each page's scroll offsets back:

```yaml
fespalier:
  scroll_restoration: true
```

```dart
// lib/app/products/page.dart
ListView.builder(
  key: const PageStorageKey<String>('products'), // without this key, nothing is restored
  itemBuilder: (context, i) => ...,
)
```

**Only a scrollable under a `PageStorageKey` is restored.** Flutter keeps an offset in the nearest
`PageStorage`, by key, and stores nothing for a scrollable that has none; fespalier does not make keys up.

- Two scrollables on one page can't swap offsets: give each its own key (a carousel in a list,
  `PageStorageKey('featured')` and `PageStorageKey('feed')`).
- A `PageView` and an `ExpansionTile` keep their position in the same place, so the same key restores them.

With the key on, the generated router wraps the page's own view, inside its transition and under its layouts,
in `RouteScrollMemory`:

```dart
GoRoute(
  path: 'about',
  builder: (context, state) => RouteScrollMemory(
    state: state,
    child: _i4.page(),
  ),
),
```

`data.dart`, `deferred`, `remount` and segment pages are wrapped the same way; layouts, redirects and
not-found views are not. `RouteScrollMemory` gives the page a `PageStorage` bucket of its own per history
entry, and what it does with it depends on how the page was reached:

- **The browser brought the entry back** (back, forward, or a reload of the tab): the page gets the bucket the
  entry had, so its keyed scrollables return to where they were. fespalier tells from go_router: it keeps the
  history state the platform hands over, and replaces it with a marker of its own for every navigation the
  app starts.
- **Anything the app starts** (`go`, `push`, `replace`, a `RouteLink`, the first route) gets a fresh bucket, so
  the page starts at the top, and the bucket replaces the one kept for that location.
- **A location the platform reports without history state** (a link opened from outside) counts as the
  app's, so it starts at the top too.

An entry is its matched location, plus the query for the page that is the top of the location (`/search?q=a`
and `/search?q=b` are two entries; `/products` below `/products/42` is `/products`).

Things to know:

- **A page that stays mounted keeps its live scroll.** The page below a child route, a tab, and a page whose
  URL changes in place (`remount: never`, `/c/1` to `/c/2`, or `?page=2` through `copyWith`) are the same
  widgets throughout, so nothing is restored for them; the bucket just moves to the new location. On Android
  and iOS back is a pop and the page below is still mounted.
- **The memory is in memory.** A router keeps the buckets of its 64 most recent entries (the oldest is
  forgotten first), each router has its own, and a reload of the browser tab starts empty. The same location
  twice in the history is one entry: A, B, A, B and back twice restores the second A's offset.
- **A list that grows as it scrolls** (infinite scroll) is rebuilt with its first items only, and Flutter
  clamps the saved offset to what is there. A list that waits for `data.dart` is fine: its offset is applied
  when the list is first built, after `loading.dart`.
- Off, the generated file has no `RouteScrollMemory` at all.

**Testing.** Play the browser: the entry has to come back with the history state the app gave the platform
(`routeInformationUpdated`), as it does in a browser. A `pushRouteInformation` with a location alone is a
location from outside, and starts at the top. `examples/features/test/scroll_restoration_test.dart` records
the state with a mock handler on `SystemChannels.navigation` and sends it back:

```dart
await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
  'flutter/navigation',
  const JSONMethodCodec().encodeMethodCall(
    MethodCall('pushRouteInformation', {'location': '/feed', 'state': saved.state}),
  ),
  (_) {},
);
await tester.pumpAndSettle();
```

`examples/features` has `/feed` with two keyed lists, a horizontal one and a vertical one, and tests for back,
forward, a `go` that starts at the top, and the two lists keeping their own offsets.
