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
ProductRoute(id: 42).replace(context);       // like context.replace
ProductRoute(id: 42).location;               // '/products/42'
const SearchRoute(q: 'ap', page: 2).location; // '/search?q=ap&page=2'
```

- Segments are **required** constructor arguments and query parameters
  **optional** ones, typed. The constructor is `const` when its arguments are.
- `.location` includes the **mount prefix** (`AppRoutes.base`), so it stays
  right under `AppRoutes.mount(at: '/shop')`. It is always the **canonical**
  spelling; `locationFor(locale)` and `locale:` pick a localized one (see
  `route-dart.md`).
- `go`, `push` and `replace` are `context.go`, `context.push<T>` and
  `context.replace` on `locationFor(locale)`.
- `watch`, `read`, `prefetch`, `preload`, `refresh`, `ref` and `keepFor` cannot be
  segment or query names: the class has those members (`fespalier-data`;
  `preload` is reserved since 0.5.0).
- To **link** to a route from a widget, `RouteLink(to: route, builder: ...)` does
  what `route.go(context)` does and adds an `href` on the web and preloading (see
  [`links.md`](links.md)).
- Build typed links rather than string paths: the compiler then checks the
  arguments, and a renamed folder breaks the build instead of a link.

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
GuardResult guard(ProviderContainer c, {Note? extra}) =>
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
