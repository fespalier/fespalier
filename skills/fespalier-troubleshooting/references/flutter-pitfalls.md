# Flutter and project pitfalls seen with fespalier

As of v0.4.0. None of these is an `fsp` message; each shows up in Flutter or in the
running app. Those marked **(reproduced)** were reproduced against v0.3.0 while
these skills were written.

## A `ListTile` asserts about its ink **(reproduced)**

```text
ListTile background color or ink splashes may be invisible.
The ListTile is wrapped in a ColoredBox that has a background color. Because ListTile
paints its background and ink splashes on the nearest Material ancestor, this ColoredBox
will hide those effects.
To fix this, wrap the ListTile in its own Material widget, or remove the background color
from the intermediate ColoredBox.
```

Pages render **below their layout's `Scaffold`**, so during page transitions the
layout's `Scaffold` is not their nearest `Material`. Give the page a surface of its own:

```dart
Material(type: MaterialType.transparency, child: ListView(children: [...]))
```

The README's "Things to know" lists this, and the project's own `products/page.dart`
example does it. It shows under `pumpAndSettle` in tests too, as a thrown assertion.
(Since 0.4.0 the `fsp init` starter `layout.dart` wraps `child` in a transparent
`Material`, so a new app does not hit it; the 0.3.0 starter does not, and `fsp init` never
rewrites an existing layout.)

## A stale `app.g.dart` **(reproduced)**

Symptoms: `flutter analyze` says **`The function 'ExtraRoute' isn't defined`** (or an
undefined class, or a constructor argument that no longer exists) for a route you just
added, renamed or re-typed; or the app shows old behaviour after a rename; or a type
error points **inside `app.g.dart`** after you changed a constructor.

- `fsp check` **does not see it**: it writes and compares nothing and exits 0.
- `fsp gen` fixes it: `✓ N routes → lib/app.g.dart`. `fsp watch` does it on every save,
  **including** an enum declared outside `lib/app/` (it watches `lib/` since 0.3.0).
- After a **merge conflict in `app.g.dart`**, regenerate; never hand-merge it.
- After **bumping the `fespalier` package**, regenerate: the generated code relies on
  the runtime of the same release. `dart run fespalier gen` runs the `fsp` that matches
  the package your `pubspec.lock` resolved; an `fsp` on `PATH` of another version does
  not (`fsp --version` prints `fsp` and its version; compare it with the package's version).
- To make CI catch it: `dart run fespalier gen` then `git diff --exit-code lib/app.g.dart`.

If `fsp gen` itself **fails**, the old `app.g.dart` is kept (`N error(s); lib/app.g.dart left
unchanged`): fix the error first, never edit the file.

## A page shows defaults, or a value arrives as `null`

Parameters are bound **by name** to the segments of the **path as `fsp` sees it**.
`$productId` in the folder and `this.id` in the page is `` can't fill `id` ``; but an
**optional nullable** parameter (`String? title`) that matches nothing is silently a
**query parameter**, so the page asks for `?title=` and gets `null`. Run
`fsp routes --json` and read `params`: `in: path` for segments, `in: query` for the
rest. A `Color? color` (a type that is no query type and no enum) is left to its default
instead.

## `/docs` is not found though `docs/$$rest` exists

`$$rest` matches **one or more** parts, so the bare `/docs` is not found; use `$$$rest`
(zero or more, and do **not** also give `docs/` a `page.dart`: both serve `/docs`), or add
`docs/page.dart` beside `$$rest`. A typed catch-all sends the **whole route** to
`not_found.dart` when **one** part does not parse (`/compare/3/x` with `List<int>`).

## A URL works in one case only **(reproduced)**

Paths are **case-sensitive** by default, like go_router: `/Products` is not `/products`
(`Nothing at /Products`). Set `case_sensitive: false` in the pubspec, or a
`route.dart` with `const caseSensitive = false;` per folder (nearest wins). Then
the router's location **keeps the requested case** (`/Products/2`), but
`ProductRoute(id: 2).location` always writes the folders' spelling, and a `$segment`
keeps the case it was typed in. Enum segments match by exact `name` first, in any case
only where the route is case-insensitive. A trailing slash never matters.

## `not_found.dart` looks unstyled or transparent

It shows **without any layout**, so it has no `Scaffold` or `SafeArea` unless it brings
its own. The root one is also what go_router's error builder shows for any URL nothing
matches; without one, users see `Nothing at /path`.

## A blank page for a moment

A route with a `data.dart` **builds nothing until the data has arrived**: `loading.dart`
(or the default centred spinner) shows first. A `loading.dart` that returns an empty
widget is a blank screen. With the default `keep_previous: true` only the **first** load
shows it.

## `$` in an import

`import 'package:my_app/app/products/$id/page.dart';` is a Dart error (`URIs can't use
string interpolation`). Escape it: `products/\$id/page.dart`.

## go_router 18 and `MaterialApp`

With Flutter's `MaterialApp`, go_router 18 checks for `package:material_ui`'s app, so
routes **without a `transition.dart` do not animate** and its own error screen is
unstyled. Keep the root `transition.dart` that `fsp init` writes
(`Transitions.material(key, child)`); it works with both 17 and 18. Do not mix
`material_ui`'s `MaterialApp` with widgets from `package:flutter/material.dart` unless
you import `material_ui` everywhere: the themes are separate.

## The web

URLs are hash URLs (`/#/products/1`) until you call `usePathUrlStrategy()` (with
`flutter_web_plugins: {sdk: flutter}`) before `runApp`, and the server must serve
`index.html` for unknown paths. An `extra` does not survive a reload without an
`extra_codec.dart`; in a release build for the web the codec's default type names are
minified, so use `names:` for data that must survive a deployment.

## Two `mount` calls, or `mount` in a host router

`AppRoutes.mount(at:, navigatorKey:)` **stores** both in static fields; the typed routes
read `AppRoutes.base`. Mount once. A host router must pass its **own** `navigatorKey`
whenever a folder uses `navigator.dart` or `present.dart`, or go_router asserts that a
`parentNavigatorKey` is not an ancestor navigator's.

## Deep links build the whole stack

A deep link to `/products/2` builds `/products` underneath it, so `/products`' `data.dart`
runs too (and a dialog or sheet route needs that parent page to have something to open
over). Tests with delayed fakes must pump for both.

## Hot reload does not regenerate

Changing the route tree (a new file, a renamed folder, a new parameter) needs `fsp gen`;
hot reload only picks up what `app.g.dart` already says. Keep `fsp watch` running next to
`flutter run`.

## After `flutter create`

`test/widget_test.dart` refers to the `MyApp` you replaced, so `flutter analyze` fails on
it until you delete or rewrite it. `flutter create` also writes the platform folders;
`fsp init` does not touch them.

## Types that look the same but are not

`fsp` reads a syntax tree. `Product` and a `typedef` of it, `List<int>` and `List<num>`,
or one enum name declared in two files, are **different** types to it and produce the
"X in file:line but Y here" error. The Dart compiler still checks the generated code.
