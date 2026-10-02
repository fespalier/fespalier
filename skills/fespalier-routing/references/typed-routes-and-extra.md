# Typed routes, `extra` and `extra_codec.dart`

As of v0.4.0.

## Typed routes

Every page and redirect gets a generated class, `final class XRoute extends
TypedLocation`, named after the page class (`ProductPage` becomes
`ProductRoute`; `Page`, `Screen` or `View` is dropped), after the folder path
for a page **function** (`orders/$orderId/cancel/page.dart` is
`OrdersOrderIdCancelRoute`) and for a `redirect.dart` (`old-products/$id/` is
`OldProductsIdRoute`), or after `const routeName = 'KycShopName';` in
`page.dart` (the route is `<routeName>Route`). Two routes with one name are an
error that suggests `routeName`.

```dart
ProductRoute(id: 42).go(context);            // replaces the stack, like context.go
await ProductRoute(id: 42).push<bool>(context);   // Future<bool?>, like context.push
ProductRoute(id: 42).replace(context);       // go + replaced history entry (since 0.6.0)
ProductRoute(id: 42).location;               // '/products/42'
const SearchRoute(q: 'ap', page: 2).location; // '/search?q=ap&page=2'
```

- Segments are **required** constructor arguments and query parameters
  **optional** ones, typed. The constructor is `const` when its arguments are.
- `.location` includes the **mount prefix** (`AppRoutes.base`), so it stays
  right under `AppRoutes.mount(at: '/shop')`. It is always the **canonical**
  spelling; `locationFor(locale)` and `locale:` pick a localized one (see
  `route-dart.md`).
- `go` and `push` are `context.go` and `context.push<T>` on `locationFor(locale)`.
  `replace` is `context.go` inside `Router.neglect` on every platform (since 0.6.0) when
  the page on top is part of the declarative stack, and `context.replace` when that page
  was pushed. See "`go`, `push` and `replace` and the address bar" below.
- `watch`, `read`, `prefetch`, `preload`, `refresh`, `ref`, `keepFor` and (since 0.5.0)
  `of`, `maybeOf` and `copyWith` cannot be segment or query names: the class has those
  members (`fespalier-data`, and the next section; `preload` is reserved since 0.5.0).
- To **link** to a route from a widget, `RouteLink(to: route, builder: ...)` does
  what `route.go(context)` does and adds an `href` on the web and preloading (see
  [`links.md`](links.md)). `route.preload(ref)` starts the page's data, and since 0.7.0 its
  code when the route is deferred.
- Build typed links rather than string paths: the compiler then checks the
  arguments, and a renamed folder breaks the build instead of a link. A string
  path is allowed, though, and `fsp` checks it (next section).

## String paths

Since 0.7.0. `context.go('/products/2')` works, and is the right thing for a path you only
have as a string (a CMS link, a notification payload, a path from another router). `fsp
gen`, `check` and `watch` read the string **literals** your code gives the router and warn
about one that **matches no route**. A path that matches is fine; typed routes are
preferred, not forced.

``warning: no route matches `/prodcts/2`, so it shows not-found; did you mean `/products/2`? [unknown_path]``,
with a code frame in the file it is in. The messages, and what each means, are in
`fespalier-troubleshooting`, `references/diagnostics-config-and-meta.md`.

- **Checked:** the first argument of `.go(`, `.push(` (`push<T>(`), `.pushReplacement(` and
  `.replace(` on any receiver, `RouteLink(uri: Uri.parse('...'))`, and `initialLocation:` of
  `AppRoutes.router(...)` and `GoRouter(...)`. **Not checked:** `go('/x')` with no receiver,
  `goNamed`/`pushNamed`, typed routes, `TabOptions(initialLocation:)` (it has its own error),
  `AppRoutes.match`/`dataAt`/`preload`, a path in a variable or built with `+`.
- **Matching** is `AppRoutes.match`'s: segments, catch-alls, case by the route's own setting,
  every localized spelling, decoded `%` escapes. `redirect.dart` is a route, `not_found.dart`
  is not. The query and fragment are ignored. **Segment types are not checked**: `/products/abc`
  matches `products/$id` when `id` is an `int` (it still shows not-found at run time).
- **Interpolation:** only what comes before the first `$` is checked, up to the last complete
  segment: `'/products/$id'` is fine, `'/prodcts/$id'` is flagged, `'/products/$id/revews'` is
  **not** (a value can hold a `/`). A relative path, a URL and one that starts with `$` are skipped.
- **Files:** every `.dart` file under `lib/` except `*.g.dart`, the generated outputs and
  folders that start with `.`. **Not `test/`**, `integration_test/` or `bin/`: tests navigate
  to unknown paths on purpose.
- **Mount:** `AppRoutes.mount(at: '/shop')` is read from `lib/`; only paths under it are
  checked, so a host router's own paths are left alone. An `at:` that is not a literal (or two
  different ones) turns the check **off** for the run, without a message. With the tree mounted
  at `/` a host router's own string paths are warned about: silence them or set `off`.
- **Silence one:** `// fsp:ignore unknown_path` on the line above (or after the path); it
  covers the call on the next line, however many lines it takes. `// fsp:ignore-file
unknown_path` silences a file. `lints: unknown_path: off` in the pubspec turns it off;
  `error` makes `fsp check` fail (config: `fespalier`, `references/cli-and-config.md`).

## The URL as state: `of` and `copyWith`

Since 0.5.0, every typed route reads itself from the current location and copies
itself with a part changed, so a widget can keep UI state (a filter, a sort, a
page) in the URL instead of in its `State`: shareable, deep-linkable, and back and
forward move between the views.

```dart
final route = SearchRoute.of(context);        // the typed route at the current location
final maybe = SearchRoute.maybeOf(context);   // null instead of throwing
route.copyWith(page: (route.page ?? 1) + 1).go(context);   // a history entry
route.copyWith(sort: Sort.name, page: null).go(context);    // null clears a query parameter
SearchRoute(q: 'ap').copyWith(page: 2).location;            // '/search?q=ap&page=2'
```

```dart
// lib/app/products/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

enum Sort { name, price }

class ProductsPage extends StatelessWidget {
  const ProductsPage({super.key, this.sort, this.page});

  final Sort? sort; // ?sort=name
  final int? page; //  ?page=2

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('sorted by ${sort?.name ?? 'default'}, page ${page ?? 1}'),
      const _Controls(),
    ],
  );
}

// Below the page, and not handed `sort` or `page`: it reads the route.
class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) {
    final route = ProductsRoute.of(context);
    return Row(
      children: [
        TextButton(
          // page: null leaves ?page= out of the URL: page 1 is the plain URL.
          onPressed: () =>
              route.copyWith(sort: Sort.name, page: null).go(context),
          child: const Text('By name'),
        ),
        TextButton(
          onPressed: () => route.copyWith(page: (route.page ?? 1) + 1).go(context),
          child: const Text('Next'),
        ),
      ],
    );
  }
}
```

```dart
// test/products_url_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/app/products/page.dart' show Sort;

void main() {
  // The state is a value: no widget, no router.
  test('copyWith leaves out what is not given and clears what is null', () {
    const route = ProductsRoute(sort: Sort.name, page: 2);
    expect(route.copyWith(page: 3).location, '/products?sort=name&page=3');
    expect(route.copyWith(page: null).location, '/products?sort=name');
    expect(route.copyWith().location, route.location);
  });
}
```

- **`of(context)`** parses the location the widget belongs to with the parsers
  `AppRoutes.match` uses (`AppRoutes.matchUrl`): the mount prefix is taken off, a
  localized spelling is the route it spells, and the case setting, enums, lists
  and catch-alls read as they do for the page. It **throws** a `StateError`
  naming the location when that is another route, and go_router's `GoError`
  outside any route; `maybeOf` returns `null` in both cases.
- **Which location:** `GoRouterState.of(context)`'s, so the route _around the
  widget_, not the page on top. A page reads the part of the URL its own route
  matched, with the URL's query; a page under a pushed one, and a tab that is
  built but not shown (`preload`), read their own; a layout (shell, tab layout)
  reads the whole location. The widget rebuilds when its route's state changes.
- **`copyWith` takes every segment and query parameter**, typed like the field.
  A parameter left out keeps its value; **`null` clears an optional query
  parameter**, which is not the same as leaving it out. A segment or a `List`
  isn't nullable (`copyWith(id: null)` doesn't compile): clear a list with an
  empty one (`tags: const []`). `extra` and the locale are not parameters:
  pass them to `go(context, extra:, locale:)`.
- It works by a **getter of a function type** with a private `const` sentinel
  behind it (see the README's Design notes): nothing is `dynamic`, constructors
  stay `const`. In `app.g.dart` it looks like `SearchRoute Function({String? q,
int? page}) get copyWith => _copyWith;`; never edit it.
- **`go`, `push` and `replace` and the address bar** (web).
  - `go` adds a history entry and the URL is the new location.
  - `replace` (since 0.6.0) shows the new location too and **replaces** the history entry,
    so use it for a change that should not pile up in back (a search box). When the page
    on top is part of the declarative stack it is `go` inside `Router.neglect`
    (`replaceLocation(context, location)` in the runtime): the stack becomes the one the
    new location has by itself, a page with the same path template keeps its state, and
    `extra` is passed on. When the top page was `push`ed it is go_router's `replace`
    (the pushed stack stays), because a `go` would drop it.
  - `pushReplacement<T>` (since 0.7.0) is go_router's, with `locale:` and, for a route that has
    one, a typed `extra:`: the top page leaves and the new one is pushed under a **new page
    key**, so nothing of the old page's state or transition is kept; the future completes with
    what the new page pops with. Use it, not `replace`, where one kind of page hands over to
    another (a sheet to a full page): over a pushed page `replace` keeps its key (go_router's
    `replace`), and over a page of the declarative stack it is a `go`, which keeps it only for
    the same path template. The replaced page's own future never completes, and when it was
    the only page, neither does this one (go_router's behaviour). Like `push`, it is in the address bar only with
    `push_updates_url: true`.
  - `push` is not in the address bar by default: go_router keeps the pushed page out of
    the route's `uri` unless `GoRouter.optionURLReflectsImperativeAPIs` is true.
    `push_updates_url: true` in the pubspec's `fespalier:` section (since 0.6.0) makes the
    generated `AppRoutes.router()` set it. The generated code assigns it on **every**
    `router()` call, `true` or `false`, so no test leaks it into another. The cost is
    go_router's: a reload or a deep link of a pushed route's URL builds that route's own
    stack, not the stack it was pushed onto. Every fespalier route is a typed path, so the
    URL is always a valid page.
  - On 0.5.0 `replace` was go_router's `replace` in every case: over a page with none
    below it the new URL showed up as a new history entry, otherwise the address bar showed
    the page below's URL. Use `go`
    for URL state there.
- **The page's own state** (a scroll position, a text field) stays across a `copyWith` that
  only changes query parameters, as it does for any change of a parameter by default
  (`Remount.never`) and under `Remount.onSegments`; `Remount.onLocation` starts the page again
  on each one. To keep it across `page: 2` and still start fresh for another `id`, put
  `const remount = Remount.onSegments;` in the folder's `route.dart` (since 0.6.0;
  [`route-dart.md`](route-dart.md#remount-start-a-page-again-when-its-url-changes)).
- **Testing:** a browser's back or forward is the platform telling the app the
  entry it moved to; `examples/shop/test/url_state_test.dart` simulates it with
  a `pushRouteInformation` message and checks each `routeInformationUpdated`.
  Build one router per test and do not `pumpAndSettle` a page with an endless
  animation.

## Typed `extra`

go_router can carry an object with a navigation that is not part of the URL:
`context.go(location, extra: product)`. A **page** asks for it with a parameter
called `extra`, and the typed route takes it as an optional argument, checked at
compile time.

```dart
// lib/models/note.dart
class Note {
  const Note(this.id, this.title);

  factory Note.fromJson(Map<String, dynamic> json) =>
      Note(json['id'] as int, json['title'] as String);

  final int id;
  final String title;

  Map<String, dynamic> toJson() => {'id': id, 'title': title};
}
```

```dart
// lib/app/notes/$id/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/models/note.dart';

class NotePage extends StatelessWidget {
  const NotePage({super.key, required this.id, this.extra});

  final int id;
  final Note? extra; // nullable: the URL alone can't produce it

  @override
  Widget build(BuildContext context) =>
      Text('note $id: ${extra?.title ?? 'no extra'}');
}
```

```dart
// lib/app/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/models/note.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () =>
        const NoteRoute(id: 3).go(context, extra: const Note(3, 'Shopping')),
    child: const Text('Open note 3'),
  );
}
```

`NoteRoute(id: 3).go(context, extra: 'oops')` is a **compile error**: a `String` is
not a `Note?`. `push<T>` and `replace` take `extra:` too.

- **The parameter must be nullable** (`Note?`, `Object?` or `dynamic`); anything
  else is an error: `` `extra` gets the object passed on navigation, but it isn't in
the URL: a deep link or a reload leaves it null, so declare it nullable, e.g.
`Note? extra` ``.
- **The object is not in the URL.** A deep link, a page opened from
  `context.go('/notes/3')` and (without an `extraCodec`) a reload or a restored
  state all get `null`. Build the page from the URL (`id`) and treat `extra` as a
  shortcut, never the source of truth.
- Passing an object of the wrong type around the typed route (a plain
  `context.go(location, extra: ...)`) is an **assertion error in debug builds**
  and reads as `null` in release (`extraOf<T>`).
- `extra` is a **reserved** name: a segment cannot be called `extra`, and a
  query parameter of that name is the extra, not `?extra=`.
- **The one place the generated file names your type.** It imports the type by
  name (`show Note`) from **each of the page file's own imports** (a library that
  does not export it is ignored; a type declared in the file itself, or under an
  import prefix, is found too). So the type must be reachable from the file's
  imports. `dart:core` types need nothing.
- **Not in a deferred page (since 0.7.0).** A class declared in a `page.dart` that is
  [deferred](route-dart.md#deferred-load-a-pages-code-on-demand) can't be named by the
  generated file outside the page, so it is an error (`` `Note` is declared in this page.dart, which is deferred, ... ``, in full in
  `fespalier-troubleshooting`). Move the type to a file of its own, or say
  `const deferred = false;` in the folder.

### Layouts, guards and redirects take it too

A `layout.dart`, `guard.dart` or `redirect.dart` can ask for `extra` the same
way (nullable; a guard and a redirect take it as a **named** parameter). Each
gets the extra of the location it is at now, `state.extra`:

```dart
// lib/app/notes/layout.dart
import 'package:flutter/material.dart';
import 'package:my_app/models/note.dart';

class NotesLayout extends StatelessWidget {
  const NotesLayout({super.key, required this.child, this.extra});

  final Widget child;
  final Note? extra;

  @override
  Widget build(BuildContext context) =>
      Column(children: [Text('frame: ${extra?.title ?? '-'}'), child]);
}
```

```dart
// lib/app/notes/$id/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/models/note.dart';

// A draft isn't shown yet.
GuardResult guard(Ref ref, {Note? extra}) =>
    extra?.title == 'draft' ? const HomeRoute().location : null;
```

A layout or guard sees the extra of **every** route it covers, so its type must
fit theirs:

- Take `Object?` (or `dynamic`) to accept anything, or **the type of the routes
  it covers** (`Note?` above pages that take `Note?`). A route that takes no
  extra puts no condition on it.
- A layout above routes with **different** extra types must take `Object?`, or
  it is an error at its parameter, with a code frame that lists the routes:
  `` `extra` is `String?` here, but the routes it covers take other types: `/n/a` (n/a/page.dart takes `int?`); ... ``
- A page's (or redirect's) own type decides for its route; on a route without
  one, the guards and layouts above it must agree with each other. A layout is
  not compared with a `redirect.dart` route below it, which never shows it.
- A route that takes no extra of its own gets the type its guards and layouts
  agree on, so `NoteRoute(...).go(context, extra: note)` is typed even if the page
  ignores it. `Object?` says nothing about a type and adds no typed argument.
- **A wrong type never crashes them.** A layout, guard or redirect reads an
  object that is not a `Note` as `null` (`extraOrNull`). Only a page asserts.

## Restoring `extra`: `extra_codec.dart`

go_router keeps a navigation's `extra` next to its location for the browser's
history and state restoration, but can only save **JSON**. Without help an
object with `toJson()` comes back as a `Map`, and any other object is dropped
(go_router logs a warning): a page that asks for `Note?` gets `null` in release
and an assertion in debug. Give the router an `extraCodec`.

```dart
// lib/app/extra_codec.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/models/note.dart';

final extraCodec = ExtraCodec({
  Note: (toJson: (Note n) => n.toJson(), fromJson: Note.fromJson),
});
```

`lib/app/extra_codec.dart` sits at the **root of the app folder** (a `const`, a
`final` or a getter; `fsp` only looks for the name `extraCodec`, and there is no
config key). The generated `AppRoutes.router()` passes it as
`GoRouter(extraCodec: ...)`.

- `ExtraCodec` takes each type and how it becomes JSON and back (annotate the
  parameter of `toJson`; a constructor tear-off does for `fromJson`), and saves
  an object under its type's name. `null`, strings, numbers, booleans and plain
  JSON lists and maps need no entry.
- **It never breaks navigation.** An unregistered type is saved as `null`, and
  saved data that no longer reads (the type was removed, or `fromJson` throws)
  comes back as `null`, so a page falls back to what the URL says. Pass
  `strict: true` to throw instead, in a test that checks you registered every
  type.
- The type is looked up by its **exact runtime type**: register each subclass of
  a sealed class.
- The name is `Type.toString()`, which a **release build for the web minifies**
  (stable within a build, different in the next). To keep saved data readable
  across deployments, name the types: `ExtraCodec({...}, names: {Note: 'note'})`.
  Two types with one name are an `ArgumentError`.
- Write your own `Codec<Object?, Object?>` if you prefer
  (`const extraCodec = MyCodec();`).
- **`AppRoutes.mount()` does not take it.** A router you build yourself passes
  `extraCodec: extraCodec` (imported from that file) to `GoRouter`, and a router
  restores only what it is given a `restorationScopeId` for.
- `extra_codec.dart` in a subfolder is a **warning** (ignored); a file with no
  `extraCodec` is an **error**.
