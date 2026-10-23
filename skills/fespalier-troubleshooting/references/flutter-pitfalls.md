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

`docs/troubleshooting.md`, "Things to know" lists this, and the project's own `products/page.dart`
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

## `lib/app.g.dart` vanishes after `build_runner` **(reproduced)**

Symptoms: after `dart run build_runner build` (or `watch`, or `fsp dev` with a `build_runner` task, or `fsp run codegen`)
`flutter analyze` says `Target of URI doesn't exist: 'package:my_app/app.g.dart'`, though `fsp gen` wrote the file a
moment ago. Nothing was logged, and `-d` makes no difference.

Cause: the builders that write `.g.dart` files (json_serializable, riverpod_generator, ...) claim an `X.g.dart` for
**every** `X.dart` in the package (source_gen's combining builder), and build_runner deletes a file at an output path
it did not write (always, since 2.7.0, which ignores `-d`). With a **`lib/app.dart`** in the app, `lib/app.g.dart`,
fespalier's default output, is one of them. `lib/app.dart` is a common name, so this is common. The first `fsp gen`
afterwards writes the file again, and the next build deletes it again; `fsp watch` does not notice (it ignores its
own output).

- **Since 0.17.0** `fsp gen`, `check`, `watch` and `dev` warn when the output is `X.g.dart`, `X.dart` is beside it and
  `build_runner` is a dependency (the text: `references/diagnostics-config-and-meta.md`).
- **The fix is either of two:** `output: lib/routes.g.dart` in the `fespalier:` section of pubspec.yaml (then
  `fsp gen`; the generated `main()` moves with it to `lib/routes.main.g.dart`, and the files for the old name are
  yours to delete), or renaming `lib/app.dart`. Any `.g.dart` with no `.dart` beside it, or a name that is not a
  `.g.dart` at all, is safe.
- **On 0.16.0 and earlier** nothing warns: look for a `lib/app.dart` (and `lib/app.main.dart`, `lib/app.routes.dart` for
  the other outputs) when the file goes missing.
- **A third way**, when `lib/app.dart` must stay and the output must not move: keep `lib/app.dart` out of the
  combining builder in `build.yaml` (checked with build_runner 2.16.1 and json_serializable 6.14.1), so nothing claims
  `lib/app.g.dart`. `lib/app.dart` can then have no generated parts of its own, and `fsp` does not warn when it reads
  exactly this (that builder, `exclude:`, the file spelled as in the warning, no glob):

  ```yaml
  # build.yaml
  targets:
    $default:
      builders:
        source_gen:combining_builder:
          generate_for:
            exclude:
              - lib/app.dart
  ```

- `generate_for` of the _other_ builders (json_serializable and the like) does not help: it is the combining
  builder that owns every `.g.dart`. (It can still keep a builder off `lib/app.g.dart` and `lib/app/**`, a large file
  that changes on every route edit.)

## A freezed `extra` is `null` after a reload **(reproduced)**

Symptoms: a page that asks for `Note? extra` shows its fallback after a web reload or `restartAndRestore`, though
`extra_codec.dart` has `Note: (toJson: ..., fromJson: ...)`; the debug console says
`fespalier: a _Note isn't registered in the ExtraCodec; ...` (0.17.0; before that nothing says anything).

Cause: freezed's `const factory Note(...) = _Note;` makes `Note(...)` a private `_Note`, and `ExtraCodec({...})`
finds a type by its **exact** runtime type, so it saves `null`. Use `ExtraCodec.of([ExtraType<Note>(...)])` (0.17.0),
which matches with `is`; see `fespalier-routing`, `references/typed-routes-and-extra.md`. freezed 4's
primary-constructor form and dart*mappable classes are their own runtime type and were never affected; built_value's
`*$Note` is not so lucky.

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

## A deferred page shows `loading.dart` for a moment, or a test cannot load it

Since 0.7.0 a route whose folder says `const deferred = true;` builds its page from a
`deferred as` import. On the web its code is a chunk the browser fetches, so the page's place
shows the nearest `loading.dart` (a centred spinner without one) until it arrives, and
`error.dart` (with a retry that loads again) if it can't be fetched. Outside the web the code is
already in the app, but `loadLibrary()` still takes a turn of the event loop, so the first visit
shows `loading.dart` for about a frame unless the code was loaded before: call
`await AppRoutes.loadDeferred();` before `runApp` there (`if (!kIsWeb) ...`), or preload it
(`route.preload(ref)`, a `RouteLink` with `preload`). A `loading.dart` that returns an empty widget is
a blank screen here too, and the landing page should not be deferred.

In a **widget test**, `pumpRouter` loads the code first. A test that pumps a router of its own
without `await tester.runAsync(AppRoutes.loadDeferred);` gets a `FlutterError` in a debug build:
`The code of products/$id/page.dart is not loaded, and a widget test can't load it while it pumps.`
(the rest of it, and the fix, are in `fespalier-testing`, `references/pitfalls.md`).

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

`fsp` reads a syntax tree, and since 0.21.0 it follows the typedefs and import prefixes of the
app's own files, and since 0.22.0 those of its `path:` dependencies: `ProductView` and the `Product`
it names are one type, and so are `m.Product` and `Product`. Still **different** types to it: a
`typedef` of a hosted, `git:` or SDK package, a generic `typedef`, `List<int>` and `List<num>`, one
enum name declared in two files, and a `typedef` of a package that only another member of a pub workspace
overrides (`fsp` reads the `dependency_overrides` of the app and of the workspace root, not of a sibling
member: write them in the root's `pubspec.yaml`). They produce the
"X in file:line but Y here" error when two files spell a segment or a query parameter differently, and
"`x` is T but data.dart yields U" for a parameter against its data. Only the messages that compare a
parameter with a `data.dart` or a section's, a form's return with its input, and an `extra` with the
routes it covers end by naming a type they found no declaration of (a `typedef` of a hosted package,
say); the "in file:line" one does not, and a segment typed with a `typedef` of a hosted package is "no
enum called `X`". The Dart compiler still checks the generated code.
