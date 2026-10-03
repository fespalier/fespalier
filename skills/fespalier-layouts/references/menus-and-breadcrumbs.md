# Menus and breadcrumbs: `nav.dart`

Since 0.8.0 (`cli/src/menu.rs`, `packages/fespalier/lib/src/nav.dart`). A drawer, a bottom bar, a
tab bar and a breadcrumb row are one list: the folders of the app and where they go. A `nav.dart`
in a folder says how that folder shows up; `fsp gen` writes `AppMenu` at the end of `app.g.dart`
from all of them. **An app with no `nav.dart` generates exactly the file it did before**, so
adding the first one is also the moment the file gains `import 'package:fespalier/nav.dart';`
and renumbers its `_iN` imports.

## What an agent writes

```dart
// lib/app/products/nav.dart
import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

const nav = Nav(
  label: 'Products',
  icon: Icons.storefront_outlined,
  selectedIcon: Icons.storefront,
  order: 1,
);

/// Optional: the label shown, localized. Named `required` segments of its folder and above are allowed.
String label(BuildContext context) => Localizations.localeOf(context).languageCode == 'fr'
    ? 'Produits'
    : 'Products';
```

- **`Nav` is in `package:fespalier/nav.dart`, not in the barrel.** Import it in the `nav.dart`
  and in a widget that names `NavItem`; a widget that only loops over `AppMenu.watch(ref)` needs
  only `app.g.dart`.
- `nav` must be **`const`**, a literal **`Nav(...)` call** (no `fsp.Nav`, no variable), and
  `order` a **whole-number literal**: `fsp` reads both from the source to sort.
- Fields: `label` (required, also the fallback), `icon`, `selectedIcon`, `order` (default 0),
  `inMenu` (default `true`; `false` keeps the entry out of `watch` but in the breadcrumbs, as
  for `orders/$id`) and `whenRefused` (`NavRefused.hide` by default, `disable`, `show`).
- A folder with a `page.dart` or `redirect.dart` is an entry that goes there. A folder with
  **neither** (a layout's or a `$team` folder) is a **heading**: it holds the entries below it, has
  no route, `enabled == false`, and is dropped with a warning when none is below it.
- `label()` is optional: `String label(BuildContext context, {required int id})`. It gets
  the `BuildContext` (locale, `AppLocalizations`, a theme) and the segments it names, typed like
  every other file in that folder. It does **not** get `data.dart`'s value.

## What it generates and how to read it

- `AppMenu.watch(WidgetRef ref, {String? under})` → `List<NavItem>`: the entries at the current
  location, nested (`NavItem.children`), each with `label(context)`, `icon` (the `selectedIcon`
  while selected), `selected`, `enabled`, `access`, `tab`, `route` and `go(context)`.
- `AppMenu.breadcrumbs(ref)` → the entries from the top down to the page (all `selected`, not
  filtered by `inMenu`, no guards asked, empty where no `nav.dart` covers the page).
- Call them in `build` of a layout or a page: they watch the router's location. Above the router
  (`MaterialApp.builder`) there is none.
- `under: '(tabs)'` returns the **topmost entries at or below that folder** (`''` is
  everything), so a tab bar is `AppMenu.watch(ref, under: '(tabs)')`, and `item.tab` is the index
  of the entry in the tab layout of **that** folder: `goBranch(item.tab!)`. A folder with no
  `nav.dart` in or below it asserts in debug: ``no nav.dart is in or below the folder `x` ``.
- **The app folder's entry and a tab layout's own page are flat**: they sit beside the entries
  below them, and are selected on their own route only. Any other entry nests the entries of the
  folders below it. Siblings sort by `order`, then by tab index, then by folder name.
- An entry whose folder has segments (`teams/$teamId`) is in the menu only at a location that
  has them; its route is built from that location. This is why a sub-menu is
  `AppMenu.watch(ref, under: r'teams/$teamId')` inside that team's layout.

## Guards

An entry is listed if the guards that run for a navigation to it let it through (those of its
folder and above, asked with the entry's own location).

| Guard answers                      | Entry                                                                                                  |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `null` at once                     | allowed, **in the first frame** of the widget that asked                                               |
| a location at once                 | refused, in the first frame: left out (`hide`), `enabled == false` (`disable`) or listed (`show`)      |
| a `Future`                         | `NavAccess.pending`: **listed and enabled**, then allowed or refused when it completes (no timer)      |
| throws                             | reported with `FlutterError.reportError`; the entry stays pending (a test must `takeException()`)      |
| `Ref` guard, watched value changes | the entry follows in the next frame, with no navigation                                                |
| `ProviderContainer c` guard        | called with the `Ref`'s container and read once per menu build: the menu does **not** follow its state |

- **A menu runs the guards.** Each guarded entry asks them once while a menu with it is on
  screen, and again when what they watch changes; keep guards cheap and free of side effects.
  `NavRefused.show` skips asking.
- A guard may read a segment: the generator builds the entry's route and passes its fields. A
  guard's query parameters get `null` (`const []` for a list) and its `extra` `null`: the entry's
  location has none.
- A test of a menu with an async guard that delays with `Future.delayed` must pump past it
  (`pumpAndSettle`), or it ends with `A Timer is still pending`.

## Traps

- Adding the first `nav.dart` renumbers the `_iN` imports of `app.g.dart`: regenerate it, never edit it.
- A `nav.dart` in a folder an older app used for something else (a helper that is called
  `nav.dart`): it is now read as the folder's menu entry. Rename it into `_components/`.
- Two widgets building the same menu share one answer per entry (one provider each); a menu that
  leaves the screen lets go of everything its guards watch.
- No labels from data (`ProductRoute.watch(ref, id: item.params['id'] as int)` in the widget
  does that), and one menu per app: use `under:` and `inMenu` to cut it up.
- `fsp new orders --nav` writes the starter; `fsp routes --json` has a `nav` key
  (`file`, `label`, `order`) on routes whose folder has one.

The diagnostics are in
[`fespalier-troubleshooting`](../../fespalier-troubleshooting/references/diagnostics-menus.md).
`examples/features` has a menu, a team sub-menu and breadcrumbs with a test for each guard case.
