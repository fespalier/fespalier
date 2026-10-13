# Transitions, shells, dialogs and state restoration

As of v0.13.0.

## `transition.dart`

`transition.dart` says how a route animates in. It applies to its **folder's route
and every route below it, the nearest one winning**; one at the root is the
app-wide default, and any folder or `(group)` can override it.

```dart
// lib/app/transition.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

// Every route fades in, unless a folder overrides it.
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.fade(key, child);
```

The function returns a `Page` and takes the page's key as `LocalKey key`, the page
itself as `Widget child`, and optionally `GoRouterState state` and `bool shell`
(below). Nothing else: ``can't fill `other`: transition() gets `key`, `child` and `state` ``.
A `transition` without a `child` parameter, or not returning a `Page`, is an
error.

The key is go_router's `state.pageKey` (the path template) for a route's page, unless the route
`remount`s (0.6.0, `fespalier-routing`, `references/route-dart.md`): then it is a
`ValueKey<String>` that changes with the URL, so a change is a **new page** and this transition plays
for it. A `transition()` that takes no `key` can't be given it, and `fsp` warns. A layout's shell
is never remounted.

`Transitions` has ready-made ones; each gives the page a `restorationId` from its
key:

| Helper                                        | What it does                                                        |
| --------------------------------------------- | ------------------------------------------------------------------- |
| `fade(key, child, {duration, heroes})`        | cross-fades (250 ms by default)                                     |
| `slide(key, child, {from, duration, heroes})` | slides in from an `AxisDirection` edge (default `right`, 300 ms)    |
| `none(key, child, {heroes})`                  | swaps instantly                                                     |
| `material(key, child, {heroes})`              | the platform-default Material transition                            |
| `cupertino(key, child, {heroes})`             | the iOS slide plus edge-swipe back                                  |
| `dialog(key, child, {...})`                   | opens as a Material dialog over the previous page                   |
| `sheet(key, child, {...})`                    | opens as a modal bottom sheet over the previous page                |
| `fullscreenDialog(key, child, {heroes})`      | a Material page that slides up, with a close button in its `AppBar` |

`heroes:` (0.8.1) is covered under "Shared elements (heroes)" below; `dialog` and `sheet` have none.

Routes with **no** `transition.dart` above them keep go_router's default for your
app type: the platform transition under a Material or Cupertino app, **none**
otherwise. With go_router 18 and Flutter's `MaterialApp` that means **none at
all** (see `fespalier/references/cli-and-config.md`): keep the root
`transition.dart` that `fsp init` writes.

## A layout's shell is a page too

The `ShellRoute` a `layout.dart` makes, and a tab layout's `StatefulShellRoute`,
take the **nearest `transition.dart`** (the layout folder's own included) as
their `pageBuilder`, so a layout moves like any other page when a route on the
root navigator opens over it. The shell's page key is
`ValueKey<String>('layout:<folder>/')` (`layout:(tabs)/`, `layout:/` for the
root), made from the layout's folder: the same on every launch (its restoration
id) and **while you switch routes inside the shell**, so **only entering or
leaving the shell animates it**, not going from one page of the layout to another.
A layout with no `transition.dart` above it keeps `layoutPage(...)`, a Material
page (Cupertino inside a `CupertinoApp`) with the restoration id. **Since 0.5.0 its
key is that same `ValueKey<String>('layout:<folder>/')`**; on 0.4.x and earlier it was
go_router's (the route object's `hashCode`), so a router built again (a hot reload, a
test) replaced the shell and lost the state of the layout and of every page in it.

**Behaviour change in 0.3.0:** since `fsp init` writes a root `transition.dart`,
most apps' layouts now get a `pageBuilder` of their transition's making. Regenerate
and check your layouts.

A `transition()` that must tell a shell from a route (to wrap a route's page in
something its shell should not get) takes **`bool shell`** (or `isShell`): `true`
for a layout's shell, `false` for a route's page. It is the only extra parameter
besides `key`, `child` and `state`.

## Page names (since 0.9.0)

Each `pageBuilder:` the generated file writes (a `transition.dart` or `present.dart` route, a `remount` route, a
layout's shell) is wrapped in `namedPage('/products/:id', () => ...)`, and the pages `Transitions.*`, `layoutPage`
and `remountPage` build while it runs are named by the route's pattern (`RouteSettings.name`). A
`NavigatorObserver` (Sentry's, Firebase Analytics', PostHog's) sees `/products/:id` where it saw `null` (a
`remount` page saw `:id`).

- A shell is named by its section's pattern: `/` for a root layout or a `(tabs)/` group, `/shop` for
  `shop/layout.dart`.
- go_router forwards a shell navigator's pushes to the root navigator's observers, so observers given to
  `AppRoutes.router(observers: ...)` see the pages inside a shell too.
- A route with **no** `pageBuilder:` (a bare `builder:`) is go_router's own page, named `state.name ?? state.path`
  (`items/:id`, not a full pattern). A root `transition.dart`, which `fsp init` writes, names every page.
- A `Page` of your own in a `transition.dart` or `present.dart` reads the name from `Transitions.pageName` (the
  pattern; null outside the generated builders): `MaterialPage(key: key, name: Transitions.pageName, child: child)`.
  `present.dart`'s page is used verbatim, so it is unnamed unless you pass that.
- Keys, restoration ids, transitions and heroes are unchanged.

```dart
// lib/app/(admin)/transition.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

// The admin layout's shell appears at once; its pages slide in.
Page<void> transition(LocalKey key, Widget child, bool shell) =>
    shell ? Transitions.none(key, child) : Transitions.slide(key, child);
```

```dart
// lib/app/(admin)/layout.dart
import 'package:flutter/material.dart';

class AdminLayout extends StatelessWidget {
  const AdminLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Column(children: [const Text('admin'), Expanded(child: child)]);
}
```

```dart
// lib/app/(admin)/users/page.dart
import 'package:flutter/material.dart';

class UsersPage extends StatelessWidget {
  const UsersPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('users');
}
```

## Dialogs, sheets and full-screen dialogs

`Transitions.dialog`, `Transitions.sheet` and `Transitions.fullscreenDialog` make a
route open **over** the previous page instead of replacing it. The page's widget
is what shows up: for `dialog` it is the dialog itself (an `AlertDialog`, a
`Dialog` or your own card, as in `showDialog`'s builder), for `sheet` the sheet's
content (wrapped in a `Material`).

```dart
// lib/app/photos/$id/transition.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

// /photos/:id is a dialog over /photos.
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.dialog(key, child);
```

```dart
// lib/app/photos/$id/page.dart
import 'package:flutter/material.dart';

class PhotoPage extends StatelessWidget {
  const PhotoPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) => AlertDialog(title: Text('photo $id'));
}
```

```dart
// lib/app/photos/sort/transition.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

Page<void> transition(LocalKey key, Widget child) =>
    Transitions.sheet(key, child, showDragHandle: true);
```

```dart
// lib/app/photos/sort/page.dart
import 'package:flutter/material.dart';

class SortPage extends StatelessWidget {
  const SortPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('sort by');
}
```

```dart
// lib/app/photos/upload/transition.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

Page<void> transition(LocalKey key, Widget child) =>
    Transitions.fullscreenDialog(key, child);
```

```dart
// lib/app/photos/upload/page.dart
import 'package:flutter/material.dart';

class UploadPage extends StatelessWidget {
  const UploadPage({super.key});

  @override
  Widget build(BuildContext context) =>
      Scaffold(appBar: AppBar(title: const Text('upload')));
}
```

```dart
// lib/app/photos/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class PhotosPage extends StatelessWidget {
  const PhotosPage({super.key});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Text('photos'),
      TextButton(
        onPressed: () => const PhotoRoute(id: 7).push(context),
        child: const Text('open 7'),
      ),
    ],
  );
}
```

They are real Navigator routes (a `DialogRoute` and a `ModalBottomSheetRoute` made by
the page), so everything works as it does for `showDialog`: `context.pop()`, the
back button and the barrier pop the route. `dialog` and `sheet` take options such
as `barrierDismissible`, `isScrollControlled`, `showDragHandle` and `enableDrag`.

- **Put the route below a page.** The page underneath stays built and visible.
  go_router builds a deep link's stack from the parents that have a page, so with
  `photos/page.dart` above `photos/$id/`, `/photos/7` opens the dialog over
  `/photos`. **Without a parent page the dialog opens over an empty screen.**
- **They cover their own navigator only.** Inside a tab, a dialog covers that
  tab's navigator, not the tab layout's navigation bar; the same goes for a
  `layout.dart`'s body. Put the route **outside** the layout's folder to cover the
  whole screen, or give it a `present.dart` or a `navigator.dart` beside its
  `transition.dart` (`fespalier-routing`).
- **They need `MaterialLocalizations`**, like `showDialog` and
  `showModalBottomSheet`: a `MaterialApp` (or a `Localizations` with the Material
  delegate) above the router.
- The route's `transition.dart` **also covers routes below it**, so give a dialog
  route its own folder.

## Shared elements (heroes)

Since 0.8.1 a shared element is one line on each side, and nothing is generated (`app.g.dart` is
unchanged):

```dart
// in the row of each product (products/page.dart)
leading: ProductRoute(id: p.id).hero('avatar', child: CircleAvatar(child: Text(p.name[0]))),

// in the product's own page (products/$id/page.dart)
ProductRoute(id: product.id).hero('avatar', child: CircleAvatar(radius: 40, child: Text(product.name[0]))),
```

- **The tag** is `route.heroTag(name)`, a `RouteHeroTag(path, name)`: the location up to the `?`
  (mount prefix included) and the name (any object; an app `enum` keeps it typo-proof). Both pages
  must name the **same route and the same name**. `hero` is an extension (`RouteHeroes`) on the typed
  routes, so a route with a query parameter called `hero` still compiles; it shadows the extension.
- **`RouteHero`** is a `Hero` that is out of flights while its tab is not shown (`TickerMode` off,
  which go_router's tab container and `examples/tabs` set). Two tabs may show one tag, and a route on
  the root navigator over the tab bar flies from the shown tab. A plain `Hero` there throws "There are
  multiple heroes that share the same tag within a subtree". A **custom tab `container`** that hides
  tabs with `Offstage` alone gets that assertion back: wrap the hidden tabs in
  `TickerMode(enabled: false)`.
- **The style** goes in `transition.dart`:
  `Transitions.cupertino(key, child, heroes: const Heroes(onBackGesture: true))`. `Heroes` has `onBackGesture` (heroes follow the back swipe;
  Flutter checks **both** pages, so set it in the root `transition.dart`), `path`
  (`HeroFlightPath.platform`, `arc` or `straight`) and `shuttle`. `heroes:` wraps the page in a
  `RouteHeroScope`, which a `RouteHero`'s own `onBackGesture:`, `path:` and `shuttle:` override; the
  nearest `transition.dart` that passes it wins, and one that doesn't leaves the tree as it was. A
  `present.dart` page or a `Page` of your own wraps its child in `RouteHeroScope(heroes: ...)`.
- **An image in a hero** (since 0.9.0, `package:fespalier_image`): use `route.imageHero(name, child: ResponsiveImage(...))`
  on both pages, or `Heroes(shuttle: ResponsiveImage.flightShuttle)` in the root `transition.dart`. Flutter's default
  shuttle rebuilds the destination's child at every rectangle of the flight, so an image that measures its box would ask for
  a URL of its own; the flight shuttle makes an image in flight start no load and show the widest variant already loaded
  ([`fespalier-images`](../../fespalier-images/references/integration.md)).
- **What does not fly.** A `dialog` or `sheet` (and a `present.dart` that builds a `PopupRoute`):
  Flutter flies heroes between page routes only, so use `fullscreenDialog`, `material` or a
  `PageRoute`. A tab switch (`goBranch`) pushes no route. A remounted page is a new route: a tag
  made from a segment differs between the two pages, a constant one flies. A page with `data.dart`
  or a deferred one flies only when it is in the destination's first frame, so
  `RouteLink(preload: Preload.intent)` or `route.preload`; otherwise `loading.dart` shows and
  nothing flies.
- **Two of one tag on one page** is Flutter's assertion: rename one, or wrap it in
  `HeroMode(enabled: false)`. An enum of names declared in a deferred `page.dart` would make the
  list page import it eagerly: put it in a file of its own.

Not built: generated per-route hero names (use an enum), and a lint for a name used on one side only.

## Scroll restoration on back and forward (since 0.8.1)

Flutter builds a page from nothing when the browser's back or forward button brings it
back, so a long list starts at the top. `scroll_restoration: true` in the pubspec's
`fespalier:` section (off by default; `fsp gen` after) wraps each page's own view in
`RouteScrollMemory(state: state, child: ...)`, which gives the page a `PageStorage`
bucket per history entry:

```yaml
# pubspec.yaml
fespalier:
  scroll_restoration: true
```

```dart
// lib/app/feed/page.dart
import 'package:flutter/material.dart';

class FeedPage extends StatelessWidget {
  const FeedPage({super.key});

  @override
  Widget build(BuildContext context) => ListView.builder(
    key: const PageStorageKey<String>('feed'),
    itemCount: 100,
    itemBuilder: (_, i) => ListTile(title: Text('Item $i')),
  );
}
```

- **Only a scrollable under a `PageStorageKey` is restored.** Flutter stores an offset by
  key and stores nothing for a scrollable without one; fespalier does not invent keys.
  Give each scrollable of a page its own key (a carousel in a list), or two lists could
  swap offsets.
- **Back and forward restore; the app's own navigation does not.** The entry gets its
  bucket back only when the browser brought it back. `go`, `push`, `replace`, a
  `RouteLink` and the first route get a fresh bucket and start at the top. A location the
  platform reports without history state (a link opened from outside) counts as the app's.
- **An entry is its matched location**, plus the query for the top page: `/search?q=a`
  and `/search?q=b` are two entries.
- **A page that stays mounted keeps its live scroll** (the page below a child route, a tab,
  a page whose URL changes in place under `remount: never`): nothing is restored for it,
  its bucket moves to the new location. On Android and iOS back is a pop, so the page below
  is still mounted.
- **In memory only**: 64 entries per router (the oldest forgotten first), a reload of the tab
  starts empty, the same location twice in the history is one entry. A list that grows as it
  scrolls is clamped to the items it has when rebuilt.
- **Layouts, redirects and not-found views are not wrapped**; with the key off the generated
  file has no `RouteScrollMemory`.
- **Testing it**: play the browser with `pushRouteInformation` _and the state the app
  reported_ (`routeInformationUpdated` on `SystemChannels.navigation`); a location alone is a
  link from outside and starts at the top. See `fespalier-testing`, `references/pitfalls.md`.

## State restoration

Pass a scope id to the router, and give the app one too, and Flutter saves what the
user was doing when the OS kills the app and puts it back on the next launch:

```dart
// lib/main.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

void main() => runApp(
  ProviderScope(
    child: MaterialApp.router(
      restorationScopeId: 'app',
      routerConfig: AppRoutes.router(restorationScopeId: 'router'),
    ),
  ),
);
```

Without the ids nothing changes. With them the location comes back (also for
routes deep in a stack), and so does everything below:

- **Tabs.** Each tab layout and each of its tabs gets a stable
  `restorationScopeId` from its folder (`layout:(tabs)/`, `tab:(tabs)/search`;
  `.` is the layout's own page), so the selected tab **and** the stack of every tab
  you visited are restored, nested tab layouts included.
- **Layouts.** A plain layout's navigator gets one too (`layout:(account)/`).
- **Pages.** What a page keeps in a `RestorationMixin` (a `RestorableInt` for a
  form field or a scroll offset) comes back if the page has a `restorationId`.
  go_router's own pages have one; the ones `Transitions.*` build take it from the
  page key; **a `Page` you build in a `transition.dart` must pass
  `restorationId: key.value` too**, or its state is not restored:

  ```dart
  // lib/app/custom/transition.dart
  import 'package:flutter/material.dart';

  Page<void> transition(ValueKey<String> key, Widget child) =>
      MaterialPage<void>(key: key, restorationId: key.value, child: child);
  ```

- **`extra`** passed with `context.go(..., extra: ...)` is saved with the location if
  the router has an `extraCodec` that knows its type (`fespalier-routing`).

Why layouts need generated pages: go_router keys the page of a `ShellRoute` or
`StatefulShellRoute` by the route object's `hashCode` and uses it as the restoration
id, which **changes on every launch**, so nothing under it can be found again. The
generated router builds these pages with an id from the layout's folder instead:
through the `transition.dart` above the layout (its `Page` under the
`ValueKey<String>` made of that id), else `layoutPage(...)`.

- **Ids come from folder names**, so renaming a folder drops what was saved under
  the old one, once.
- `AppRoutes.mount()` passes no scope id: give **your own** `GoRouter` a
  `restorationScopeId`, and pass it `extraCodec:` yourself.
- In a test, build the router in a `State`, **not** a `final`: a router remembers
  where it went (`fespalier-testing`).
