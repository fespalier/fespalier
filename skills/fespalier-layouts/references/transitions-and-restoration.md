# Transitions, shells, dialogs and state restoration

As of v0.4.0.

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

| Helper                                | What it does                                                        |
| ------------------------------------- | ------------------------------------------------------------------- |
| `fade(key, child, {duration})`        | cross-fades (250 ms by default)                                     |
| `slide(key, child, {from, duration})` | slides in from an `AxisDirection` edge (default `right`, 300 ms)    |
| `none(key, child)`                    | swaps instantly                                                     |
| `material(key, child)`                | the platform-default Material transition                            |
| `cupertino(key, child)`               | the iOS slide plus edge-swipe back                                  |
| `dialog(key, child, {...})`           | opens as a Material dialog over the previous page                   |
| `sheet(key, child, {...})`            | opens as a modal bottom sheet over the previous page                |
| `fullscreenDialog(key, child)`        | a Material page that slides up, with a close button in its `AppBar` |

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
