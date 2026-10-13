# Tab layouts: `tabs`, `tabOptions` and `container`

As of v0.13.0. A `layout.dart` that asks for a `StatefulNavigationShell` (a
parameter named `navigationShell` or `shell`, or typed that way) **instead of** a
`Widget child` is a **tab layout**. It becomes a go_router
`StatefulShellRoute.indexedStack` (or, with a `container`, your own
`navigatorContainerBuilder`), so **each tab keeps its own navigation stack and
state** while you look at another. Asking for both a `child` and a shell is an
error.

```dart
// lib/app/layout.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

// Each name is a folder as written, and '.' is this folder's own page.dart.
const tabs = ['.', 'search', 'profile'];

// Only tabs that need options are listed.
const tabOptions = {
  'search': TabOptions(preload: true),
  'profile': TabOptions(initialLocation: '/profile/edit'),
};

// Optional: arrange the tabs' navigators yourself. Keep every child in the tree.
Widget container(
  BuildContext context,
  StatefulNavigationShell shell,
  List<Widget> children,
) => Stack(
  children: [
    for (final (i, navigator) in children.indexed)
      Offstage(offstage: i != shell.currentIndex, child: navigator),
  ],
);

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
        // Tapping the current tab goes back to its first page.
        initialLocation: i == navigationShell.currentIndex,
      ),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
        NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
      ],
    ),
  );
}
```

```dart
// lib/app/page.dart
import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => const Text('home tab');
}
```

```dart
// lib/app/search/page.dart
import 'package:flutter/material.dart';

// Keeps a counter, to show that a tab's state survives switching tabs.
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

```dart
// lib/app/profile/page.dart
import 'package:flutter/material.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) => const Text('profile');
}
```

```dart
// lib/app/profile/edit/page.dart
import 'package:flutter/material.dart';

class EditProfilePage extends StatelessWidget {
  const EditProfilePage({super.key});

  @override
  Widget build(BuildContext context) => const Text('edit profile');
}
```

## Which folders are tabs

- Each **tab (a branch)** is the layout folder's own `page.dart`, if it has one
  (named `'.'`), and then **each direct subfolder that holds routes**: a static
  or dynamic folder, or a `(group)`. Whatever is below a subfolder (nested pages,
  data, guards, transitions, more layouts) stays **inside its tab**.
- Branches follow folder order (alphabetical) unless **`tabs`** lists them.
  `tabs` is a top-level `const` list of **string literals**; it must list every
  branch exactly once. Name any other list of destinations something other than
  `tabs`. The errors point at the entry:

  ```text
  `tabs` lists `zzz`, which is not a branch here; the branches are `a`, `b`
  `tabs` lists `a` twice
  `tabs` is missing the branch `b`; list every branch once (`a`, `b`)
  `tabs` must be a list of string literals naming the branches, e.g. `const tabs = ['home', 'search'];`
  ```

- A tab layout can also ask for segments and query parameters like any layout, and
  for section data.
- **A tab layout folder without its own `page.dart` has no route at its own
  path**: link to one of its tabs' routes instead.
- Routes **outside** the layout's folder are in no tab and cover the whole screen
  (`/settings` has no navigation bar). To cover the screen while the URL stays in a
  tab (`/profile/edit`), use `navigator.dart` (see `fespalier-routing`).

## The rules go_router imposes

go_router opens a tab on its **first route**, which **cannot have a `:segment`** in
its own path. So a tab made only of dynamic routes, or a tab layout placed
directly in a `$folder`, is an error:

```text
error: /a/:id is the first route of a tab, and go_router can't open a tab on a path
       with a `:segment` in it; put a page with a static path first in the tab, or move
       the tab layout below the folder that holds the segment
```

Put the layout in a `(group)` below that folder, or give the tab a `tabOptions`
`initialLocation`, which lets a tab of dynamic routes work. A catch-all as a tab's
first route needs one too.

## `tabOptions`

A top-level `const tabOptions` map, next to `tabs`, sets go_router's
`StatefulShellBranch` options per tab. Keys are the tab names `tabs` uses
(`'.'` for the layout's own page); each value is a `TabOptions` from
`package:fespalier/fespalier.dart`.

- `preload: true` builds the tab as soon as the layout first shows, instead of on
  its first visit.
- `initialLocation` is where the tab opens the first time, and where tapping its
  current tab goes with `goBranch(i, initialLocation: true)`, instead of the tab's
  first route. An app location such as `/profile/edit` (with `?query` if you
  like), as a **string literal without `$`**. It must be a **route inside that
  tab** (dynamic routes match any value: `/items/1` for `items/$id`), and `fsp`
  checks that. When mounted with `AppRoutes.mount(at: '/x')` the mount point is
  added for you. A localized tab's `initialLocation` may name a spelling.

`tabOptions`, like `tabs`, is **read from the source, not run**: a map literal
with string-literal keys and `TabOptions(...)` values with `true`/`false` and
string-literal arguments. Unknown tabs, repeated tabs, unknown options and other
values are errors that point at the entry:

```text
`tabOptions` lists `nope`, which is not a branch here; the branches are `a`, `b`, `c`
`TabOptions` has no `speed`; it takes `preload` and `initialLocation`
`preload` must be `true` or `false`
`initialLocation` `/zzz` is not a route in the `b` tab; go_router needs one of them: `/b`
```

## `container`

By default the tabs' navigators sit in an `IndexedStack`. A tab layout can export a
top-level **`container`** function to arrange them itself, say to cross-fade or
slide between tabs. The generated route is then
`StatefulShellRoute(navigatorContainerBuilder: _i1.container, ...)`; a layout without
`container` generates exactly what it did before.

- The three parameters are **positional** and their **types are fixed**:
  `BuildContext`, `StatefulNavigationShell`, `List<Widget>` (the names are yours).
  A wrong type, a missing or an extra parameter, or a return type that is not
  `Widget` is an error at the parameter: `container() takes three positional
parameters: ...` or `shell gets the StatefulNavigationShell, but it's declared int`.
- `children` holds **one navigator per tab in the layout's tab order**, and the
  container **must keep them all in the tree** (`Offstage`, `Opacity` or a
  `Stack`, as `IndexedStack` does) **or the tabs lose their state**.
- A `container` in a layout that is **not** a tab layout is ignored with a
  warning.

## Nested tab layouts

A tab layout can sit inside a tab of another: put a `layout.dart` that takes a
`StatefulNavigationShell` in a folder that is a branch of the outer layout. Each
layout has its own `tabs`, its own stacks and its own shell, and the outer layout
keeps the whole inner one alive while you look at another outer tab. The same
rules apply at each level: an inner tab cannot start on a route with a `:segment`
in its path, and a tab layout in a `$folder` is an error.

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

`library/` has no page of its own here, so its inner layout is what the outer tab
shows. Give it a `page.dart` and that page becomes the inner layout's first tab.

## Other rules that bite

- A tab layout's own folder **cannot hold a `redirect.dart`**: put it in a
  subfolder (`a tab layout folder can't hold a redirect.dart`).
- A root-navigator route (`navigator.dart`, `present.dart`) **cannot be the first
  route of a tab** or sit directly in the layout (`fespalier-routing`).
- There is no `redirect` on a plain `ShellRoute`: guards run on each page's
  route, which go_router runs for deep links and for navigation inside a shell,
  tabs included. **One exception, since 0.11.0:** the guards above a tab layout (its
  folder's own, or a page-less folder over it) are generated once, as the
  `StatefulShellRoute`'s `redirect:`, not copied into each tab's route; a tab's own
  `guard.dart` stays on its route (`fespalier-guards`).
- Tab stacks and the selected tab are restored after a restart when the router has a
  `restorationScopeId` (see `transitions-and-restoration.md`).
