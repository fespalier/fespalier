# Navigation

## Typed navigation at a glance

```dart
// the whole app entry point (since 0.8.1): lib/main.dart runs the main() fsp generates
Future<void> main() => AppMain.run();

// or by hand
MaterialApp.router(routerConfig: AppRoutes.router());

// or inside an existing GoRouter (brownfield)
GoRouter(routes: [...legacyRoutes, ...AppRoutes.mount(at: '/shop')]);

// typed navigation, generated from the tree
ProductRoute(id: 42).go(context);
const SearchRoute(q: 'ap', page: 2).go(context);   // → /search?q=ap&page=2
ProductRoute(id: 42).go(context, locale: 'fr');    // → /produits/42 (`location` stays /products/42)

// each route's data.dart, as a Riverpod provider
ref.watch(ProductRoute.data(42));
ProductRoute.watch(ref, id: 42);             // the same, typed: AsyncValue<Product>
await ProductRoute.read(ref, id: 42);        // Future<Product>
final warm = ProductRoute(id: 42).prefetch(ref);   // start loading before navigating; warm.close() lets go
await const ProductsRoute().refresh(ref);

// each route's action.dart: a write with pending and error state, then the data it made stale reloads
await ProductRoute.submit(ref, id: 42, input: refund);             // Future<Refund>, throws what it threw
final refund = ProductRoute.useAction(ref, id: 42);               // for build(): .state is AsyncValue<Refund?>

// from a location to what it reads (an app's own prefetch queue, tests): no guard runs, no widget is built
AppRoutes.dataAt(Uri.parse('/products/42'));    // [ProductRoute.data(42)]; null when no route fits
AppRoutes.match(Uri.parse('/products/42'));     // RouteMatch: the RouteInfo, the parsed params, the data
```

## The URL as state: `of` and `copyWith`

_Since 0.5.0._ A filtered, sorted, paginated list that keeps its state in the query is a link
someone can send, and back and forward move between its views. Every typed route has two ways in
and one way to change a part of it:

```dart
final route = SearchRoute.of(context);          // the typed route at the current location
final maybe = SearchRoute.maybeOf(context);     // null instead of throwing

route.copyWith(page: (route.page ?? 1) + 1).go(context);          // a history entry
route.copyWith(sort: Sort.name, page: null).go(context);           // null clears a query parameter
SearchRoute(q: 'ap').copyWith(page: 2).location;                   // '/search?q=ap&page=2': a value, no widget
```

- **`XRoute.of(context)`** parses the location the widget belongs to, with the parsers
  [`AppRoutes.match`](data.md#from-a-location-to-its-data) uses (it calls `AppRoutes.matchUrl`): the
  mount point is taken off, a [localized spelling](routing.md#localized-paths) is the route it spells, and the
  [case setting](routing.md#case-and-trailing-slashes), [enums](routing.md#enum-segments), lists and
  [catch-alls](routing.md#catch-all-segments) read as they do for the page. It throws a `StateError` that
  names the location when it is another route; `XRoute.maybeOf(context)` returns `null`. Use `of`
  in a widget below the page that wasn't handed the parameters; the page itself already has them
  as constructor arguments and rebuilds when they change. (A `const` route stays `const`:
  `of` and `copyWith` are members, not constructor parameters.)
- **Which location.** It is `GoRouterState.of(context)`'s: the route around the widget, not
  whichever page is on top. A page reads the part of the URL its own route matched, with the URL's
  query, so `/products/42?ref=mail` leaves the page of `/products` below it reading
  `ProductsRoute(ref: 'mail')`, and a page under a pushed one, a tab that is built but not shown
  (`preload`) read their own. A layout (a shell, a tab layout) is above any
  one page and reads the whole location. Outside any route (`MaterialApp(home: ...)`) `of`
  throws go_router's `GoError`, `maybeOf` returns `null`. A widget that calls it depends on its
  route's state and rebuilds when it changes, as with `GoRouterState.of`; call it in `build` or in
  a handler of a mounted widget, not after it is disposed.
- **`copyWith`** takes every segment and every query parameter of the route, by name and with the
  field's own type. One left out keeps its value; **`null` clears an optional query parameter**
  (`page: null` leaves `?page=` out of the location), which is not the same as leaving it out. A
  segment, and a `List` (a repeated query parameter or a catch-all), is not nullable, so
  `copyWith(id: null)` doesn't compile: clear a list with an empty one (`tags: const []`). It
  returns the same route class, so `.go`, `.push`, `.replace` and `.location` follow. What isn't a
  parameter isn't carried: an `extra` is given again to `go(context, extra: ...)`, and the
  localized spelling is chosen where the route is used (`go(context, locale: 'de')`), not by the
  copy.
- **How null differs from omitted.** `copyWith` is a getter whose type is a function with the
  fields' types (`SearchRoute Function({String? q, int? page, Sort? sort})`), and the function
  behind it has the parameters as `Object?` with a private `const` sentinel as the default. The
  caller sees the clean signature; the sentinel is only visible in `app.g.dart`, and nobody can
  pass it. See [Design notes](faq.md#design-notes).
- **`go`, `push`, `replace`.** `go` follows the URL: on the web it adds a history entry, and back
  and forward restore each view. `replace` (since 0.6.0) shows its location in the address bar too
  and replaces the history entry instead of adding one, so it is the one for a change that
  shouldn't pile up in the back stack (typing in a search box). When the page on top is part of the
  declarative stack it is `go` inside Flutter's `Router.neglect`, on every platform: the stack
  becomes the one the new location has by itself, and a page with the same path template keeps its
  state. When the top was `push`ed, `replace` is go_router's own, which swaps that page and keeps the
  stack below it. `push` stays out of the address bar and the history unless `push_updates_url: true`
  is set in [the pubspec](configuration.md#the-fespalier-section) (since 0.6.0). On 0.5.0 `replace` was go_router's in
  every case: the address bar followed it only when no page was below it (as a new history entry),
  and showed the page below's URL otherwise, so use `go` for URL state there.
- **`pushReplacement`** (since 0.7.0) is go_router's own, typed like `push`: the page on top leaves
  and a new one is pushed, with a new page key, and the future completes with what that page pops
  with. Use it where `replace` is wrong because the page's state or transition must not carry over:
  a sheet that hands over to a full page, or the reverse. `replace` over a pushed page keeps its key (go_router's `replace`); over a page of the declarative stack it is a `go`, which keeps it only for the same path template. The replaced page's own
  future never completes, and when it was the only page, neither does this one (go_router's
  behaviour). Both take `locale:`, and `extra:` where the route has one.
- **Reserved names.** `of`, `maybeOf` and `copyWith` are members of the route class, so
  they can't be segment or query names (see
  [Typed helpers on the route](data.md#typed-helpers-on-the-route)).
- **Cost.** Both are synchronous and use no timer or microtask. `of` matches the location with the
  generated matchers and builds one route; `copyWith` builds one (plus the small function it returns).
- **The page's own state.** A `copyWith` that only changes query parameters keeps the page and its
  widget state under `never` (the default) and `onSegments`, and starts the page again under
  `onLocation`. To keep that state across `page: 2` and still start fresh for another product,
  say `Remount.onSegments`: see [Remounting a page](#remounting-a-page-remount).

`examples/shop` keeps the list's sort and page this way (`products/page.dart`, and
`test/url_state_test.dart` with back and forward); `examples/features` has the enum, list,
catch-all and localized cases and `examples/tabs` the tabs.

## Remounting a page: `remount`

_Since 0.6.0._ A page keeps its widget state when only its URL parameters change. go_router keys a
page by its path template, so `/products/1` to `/products/2` is the same page: its widget is built
again with the new `id`, but its `State` (a scroll position, a text field, a hook's `useState`)
lives on. Some apps want that, others want a fresh page, and it depends on the app, so it is a
setting. `Remount` is an enum fespalier exports, with three values:

| Value                     | The page starts again (a fresh state) when                    | It keeps its state when                         |
| ------------------------- | ------------------------------------------------------------- | ----------------------------------------------- |
| `never` (the default)     | never: what fespalier generated before 0.6.0                  | anything changes in the URL                     |
| `onSegments`              | the value of a segment changes (`/products/1` to `/2`)        | only the query changes (`?page=2`)              |
| `onLocation`              | anything changes in the location, the query included          | the location is the same                        |

`onSegments` is the one that fits [the URL as state](#the-url-as-state-of-and-copywith): the page
keeps its state across `XRoute.of(context).copyWith(page: 2)`, and starts again on another product.

**Where to say it.** For the whole app, in the pubspec's `fespalier:` section, with `never`,
`on_segments` or `on_location`:

```yaml
fespalier:
  remount: on_segments
```

For a folder, in its `route.dart`, which then covers that folder and everything below it, the
nearest one winning over the parent's and over the pubspec, like
[`caseSensitive`](routing.md#case-and-trailing-slashes):

```dart
// lib/app/products/route.dart
import 'package:fespalier/fespalier.dart';

const remount = Remount.onSegments;
```

It is read from the source when the tree is generated, never imported or run, so it must be
`const` and one of `Remount.never`, `Remount.onSegments` and `Remount.onLocation`, written out
(an import prefix, `fsp.Remount.onSegments`, is fine), and declared once; anything else is an
error with a code frame, and so is a pubspec value that isn't one of the three (the message lists
them). Like `caseSensitive` it is inherited by `(group)` folders and folders without a page, needs
no page beside it, and a folder can say `Remount.never` to go back to the default under a parent
that remounts. `fsp routes` tags such a page `remount`, and `--json` says which in a `remount` key.

**What it keys.** Only the page of a route. The generated code gives the page a key that changes
with the URL where it used to use go_router's `state.pageKey`:

- `onSegments`: the template plus the values of the route's own path parameters, those of the
  folders above it included (`/teams/:teamId/members/:member` starts again when either changes),
  as the URL spells them. The static parts of the path (their
  [case](routing.md#case-and-trailing-slashes), a [localized spelling](routing.md#localized-paths)) are not in it. A
  route with no segment has nothing to watch, and is generated as if it were `never`.
- `onLocation`: the template, the path matched down to this route and the whole query. The fragment
  (`#top`) is not in it. A page below which another is pushed (`/orders/1` under `/orders/1/refund`)
  keeps its key and state, because the path is the route's own, not the whole location's.

A layout is not remounted, whatever its folder says: its page is keyed by its folder so that it and
its [sections](data.md#section-data) outlive a change of the URL (the pages inside it start again by their
own `remount`). Give a widget in a layout a `ValueKey` of your own if it should start again.

**A new key is a new page.** go_router treats a page with another key as another page, not an
update of the one it had: the navigator replaces the old page with the new one, so the page's
transition may play, and the old page leaves with its own. How it looks is the page's
[`transition.dart`](layouts.md#transitions) (or [`present.dart`](#presentdart-a-page-of-your-own)), which
receives the key as its `LocalKey key` parameter, as before; pass it on to the `Page` you build,
as `Transitions.fade` does. A `transition.dart` that takes no key can't give the new page one, so
`remount` has nothing to act on there, and the generator warns that `remount` has no effect there.
Without a `transition.dart` the page is a Material page, or a Cupertino one inside a
`CupertinoApp`, built like a layout's page is (`remountPage`). Use `Transitions.none` for a page
that should start again without animating.

**Not what it is for.** It restarts the page's widgets, not its data: a `data.dart` provider is
keyed by the segments and the query already, and reloads (see
[Retries and reloads](data.md#retries-and-reloads)) whether the page remounts or not. And it does not
change which route matches or what `XRoute.of(context)` reads.

`examples/features` has all three, under `remount/` (`never/` and `segments/` override the
`onLocation` of `remount/route.dart`), with a widget test that presses a button, changes the URL
and reads the count; `packages/fespalier/test/remount_test.dart` has the runtime.

## Typed `extra`

go_router can carry an object with a navigation, `context.go(location, extra: product)`,
that isn't part of the URL. A page asks for it with a parameter called `extra`, and the
typed route takes it as an optional argument:

```dart
// notes/$id/page.dart
class NotePage extends StatelessWidget {
  const NotePage({super.key, required this.id, this.extra});
  final int id;
  final Note? extra;      // nullable: the URL alone can't produce it
  …
}

NoteRoute(id: 3).go(context, extra: note);      // also push<T>(…, extra:), pushReplacement<T>(…, extra:) and replace(…, extra:)
NoteRoute(id: 3).go(context, extra: 'oops');    // compile error: a String isn't a Note?
```

The parameter **must be nullable** (`Note?`, `Object?` or `dynamic`; anything else is an
error at that parameter). The object isn't in the URL, so a deep link, a page opened from
`context.go('/notes/3')` and (without an [`extraCodec`](#restoring-extra-on-the-web)) a
reload or a restored state all get `null`: build the page from the URL (`id`) and treat
`extra` as a shortcut, not the source of truth. Passing an object of the wrong type around
the typed route (a plain `context.go(location, extra: …)`) is an assertion error in debug
builds and reads as `null` in release builds.

`extra` is a reserved name: a segment can't be called `extra`, and a query parameter of
that name is the extra, not `?extra=`. The generated file has to name the type for the
typed arguments, which is the one place it copies from your imports: it imports the type
`show`ing that name from each of the file's imports (a library that doesn't export it is
ignored; a type declared in the file itself, or under an import prefix, is found too),
so the type must be reachable from the file's own imports. The built-in `dart:core`
types need nothing.

**Layouts, guards and redirects take it too.** A `layout.dart`, a `guard.dart` or a
`redirect.dart` can ask for `extra` the same way (a nullable type; a guard and a redirect take
it as a named parameter). Each gets the extra of the location it is at now, `state.extra`:

```dart
// notes/layout.dart: the frame above every note
class NotesLayout extends StatelessWidget {
  const NotesLayout({super.key, required this.child, this.extra});
  final Widget child;
  final Note? extra;
  …
}

// notes/$id/guard.dart: a draft isn't shown yet
GuardResult guard(Ref ref, {Note? extra}) =>
    extra?.title == 'draft' ? const HomeRoute().location : null;
```

A layout or a guard sees the extra of _every_ route it covers, so its type has to fit theirs,
or it's an error at its parameter, with a code frame that lists the routes:

- A guard or layout takes `Object?` (or `dynamic`) to accept anything, or **the type of the
  routes it covers**: `Note?` above pages that take `Note?`. Nullability aside, the names have
  to match. A route that takes no extra puts no condition on it.
- So a layout above routes with different extra types must take `Object?`; otherwise the
  routes that don't fit are listed:

  ```text
  error: `extra` is `Note?` here, but the routes it covers take other types: `/notes/:id/print`
         (notes/$id/print/page.dart takes `Receipt?`); a layout sees the extra of every route it
         covers, so declare it as `Object?` to accept any of them, or as their type when they share one
    ┌─ lib/app/notes/layout.dart:3:53
  ```

  A page's or redirect's own type decides for a route; on a route without one, the guards and
  layouts above it must agree with each other. A layout isn't compared with a `redirect.dart`
  route below it, which never shows it.

- A route that takes no extra of its own gets the type its guards and layouts agree on, so
  `NoteRoute(...).go(context, extra: note)` is typed even if the page ignores it.
  `Object?` says nothing about a type: it adds no typed argument.
- **A wrong type never crashes them.** A layout, a guard or a redirect sees extras meant for
  other routes, so an object that isn't a `Note` reads as `null` (`extraOrNull`), and so does an
  extra that isn't there. Only a page asserts, as above. The type is nullable so that `null`
  always fits.

### Restoring `extra` on the web

go_router keeps a navigation's `extra` next to its location, for the browser's history and for
state restoration, but can only save what is JSON. Without help, an object with a `toJson()`
comes back as the JSON `jsonEncode` made of it (a `Map`), and any other object is dropped
(and go_router logs a warning): neither is your type, so a page that asks for a `Note?` gets
`null` in release builds and, for the `Map`, an assertion in debug builds. To get the object
back, give the router an `extraCodec`.

Put a top-level `extraCodec` in `lib/app/extra_codec.dart`, at the root of the app folder (a
`const`, a `final` or a getter; `fsp` only looks for the name). The generated
`AppRoutes.router()` passes it as `GoRouter(extraCodec: …)`:

```dart
// lib/app/extra_codec.dart
import 'package:fespalier/fespalier.dart';

final extraCodec = ExtraCodec({
  Note: (toJson: (Note n) => n.toJson(), fromJson: Note.fromJson),
  Mode: (toJson: (Mode m) => m.name, fromJson: Mode.values.byName),
});
```

`ExtraCodec` takes each type and how it becomes JSON and back (annotate the parameter of
`toJson`; a constructor tear-off does for `fromJson`), and saves an object under its type's
name. `null`, strings, numbers, booleans and plain JSON lists and maps need no entry. It
never breaks navigation: an object whose type isn't registered is saved as `null`, and saved
data that no longer reads (the type was removed, or `fromJson` throws) comes back as `null`,
so a page falls back to what the URL says. Pass `strict: true` to throw instead, in a test that
checks you registered every type.

- The type is looked up by its exact runtime type: register each subclass of a sealed class.
- The name is `Type.toString()`, which a release build for the web minifies (stable within a
  build, different in the next). To keep saved data readable across deployments, name the types:
  `ExtraCodec({...}, names: {Note: 'note'})`.
- Write your own `Codec<Object?, Object?>` instead if you like (`const extraCodec = MyCodec();`).
- `AppRoutes.mount()` doesn't take it: a router you build yourself passes
  `extraCodec: extraCodec` (imported from that file) to `GoRouter`. A router restores only what
  it is given a `restorationScopeId` for (see [State restoration](layouts.md#state-restoration)).
- `extra_codec.dart` in a subfolder is a warning, and a file without an `extraCodec` is an
  error.

`examples/tabs` does this for a `ProfileDraft` passed to its edit page, and its restoration test
restarts the app and checks the draft is still there (and, for contrast, what a router without the
codec restores). `examples/features` has a layout and a guard that read a `Note?` extra.

## The root navigator (`navigator.dart`)

A route's URL and the navigator it renders on are two decisions. A tab layout puts every route
in its folder on a tab's navigator, under the navigation bar. `navigator.dart` says that a
folder renders on the **root** navigator instead, above every layout and tab bar, without
moving its URL:

```dart
// lib/app/(tabs)/profile/edit/navigator.dart
const navigator = RouteNavigator.root;
```

`/profile/edit` is still under `/profile` (a deep link builds the Profile tab beneath it, and back
returns to it, with its state), and the page covers the whole screen. The declaration applies to
its folder's routes and to **every folder below it**, and the nearest one wins, like
`transition.dart`; a page-less `(group)` folder can hold it too, for the routes inside. `fsp gen`
emits `parentNavigatorKey: rootNavigatorKey` on the route and on all its descendants (`go_router` puts a
route on its enclosing shell's navigator unless it says otherwise, so a child pushed from the page
would land _under_ it), and the route table marks them `(root)`.

The generated file owns the key: `AppRoutes.rootNavigatorKey` is a `GlobalKey<NavigatorState>` the
app can read (the last `router()` or `mount()` call's: a call that is given no key makes a fresh one
rather than keeping an earlier call's, since 0.5.0); `AppRoutes.router(navigatorKey: …)` uses one you supply; and
`AppRoutes.mount(at:, navigatorKey: …)` takes the **host** `GoRouter`'s own key, since a
`parentNavigatorKey` must name an ancestor navigator.

- `fsp` reads the file from the source, like `tabs`: a `const navigator` that is
  `RouteNavigator.root` or `RouteNavigator.shell`, spelled out; anything else is an error at it.
- **A layout is a navigator of its own.** A `layout.dart` below a root folder becomes a
  `ShellRoute(parentNavigatorKey: rootNavigatorKey, …)` (or the `StatefulShellRoute`); the routes
  inside it sit on its own navigator, since go_router doesn't allow a key other than the shell's
  there. Below a layout nothing is inherited, and `RouteNavigator.shell` is what a folder says to
  be explicit about it. Below a root route with **no** layout in between, `.shell` is an error:
  go_router only lets a descendant use the root navigator or a navigator above it.
- **A root route can't be a direct child of a shell.** go_router lifts a route out of its shell
  only from below another route, so a root route that is the first route of a tab, or sits beside
  others directly in a layout, is an error (put it below a `page.dart` that stays in the layout, or
  move its folder out of the layout's folder).
- The typed route is unchanged: `EditProfileRoute().push(context)` and `.go(context)` as before.

`examples/tabs` does this for `/profile/edit`; its tests check that there is no `NavigationBar`, that
back returns to the tab, and that a deep link builds the tab underneath.

## `present.dart`: a page of your own

`present.dart` builds **this route's own `Page`**. It is for a sheet (or a dialog, or any page
class the app owns) with a URL: `/products/:id/buy` opens a sheet over `/products/:id`, from a
link or a deep link.

```dart
// lib/app/products/$productId/buy/present.dart
Page<void> present(LocalKey key, Widget child) => SheetPage(key: key, child: child);
```

It is bound like `transition.dart` (`key`, `child`, `state`), and what it returns is used
**verbatim**: fespalier adds no scrim, handle or shape, and ships no sheet widget. It does not name the
page either: pass `name: Transitions.pageName` (since 0.9.0, the route's pattern) for an observer to see it.
Unlike `transition.dart`:

- it applies to **its own folder only**: a folder below keeps the nearest `transition.dart` for
  its own page;
- it puts the route on the **root navigator**, over a tab bar and any `layout.dart`, and its
  descendants too (the [`navigator.dart`](#the-root-navigator-navigatordart) rules, so a child of
  a sheet renders above it, never under it, and go_router never builds the shell twice). A
  `navigator.dart` in the same folder overrides that (`RouteNavigator.shell` keeps a sheet in
  a tab);
- it needs a `page.dart` (a warning and no effect otherwise), and, to have a parent underneath on a
  deep link, the sheet's folder should sit below the parent page's folder.

The route table marks it `(present, root)`, and the manifest's `presentation` is
`RoutePresentation.custom` (fespalier can't know it is a sheet: say so in a `meta.dart` if you want
to). `examples/features` has `/photos/share`, with an app-owned `SheetPage` in `lib/`, a
child page above it, and tests for the deep link, the parent's state after popping, and the root
navigator.

## Links: `RouteLink`

`RouteLink` (since 0.5.0) is a link to a route: a real `<a href>` on the web, a plain widget
everywhere else, and a click that goes through go_router either way.

```dart
RouteLink(
  to: ProductRoute(id: p.id),     // any typed route; or `uri: Uri.parse('/products/2')`
  preload: Preload.intent,        // none (default) | intent | visible
  onPreload: (context) => ...,    // runs when the preload starts: what else the page needs (since 0.9.0)
  method: LinkMethod.go,          // go (default) | push | replace
  builder: (context, follow) => ListTile(title: Text(p.name), onTap: follow),
)
```

`builder` gets `follow`, which navigates; give it to the child's `onTap` or `onPressed`. The child
is exposed to accessibility services as a link with its URL, and `const RouteLink(...)` works when
the route and the builder are constant.

- **On the web** it is built on `url_launcher`'s `Link`, which lays an invisible anchor over the
  child. The browser shows the URL in its status bar, the context menu offers "open in a new
  tab", and a middle click, or a click with Ctrl, Cmd, Shift or Alt, opens it in a new tab or
  window. A plain click or a keyboard activation never reaches the anchor: `follow` calls
  `GoRouter.go`, `push` or `replace` (the `method`), the page doesn't reload, and the anchor's own
  navigation is cancelled. With `method: LinkMethod.push` a plain click pushes and a Ctrl-click
  opens a tab. The `href` is the route's `location`, so it carries the mount prefix
  (`AppRoutes.mount(at: '/shop')` gives `/shop/products/2`) and, with `locale: 'fr'`, the
  localized spelling `locationFor('fr')` writes. Under a hash URL strategy the browser prefixes
  it with `#`, as for any link.
- **Elsewhere** there is no anchor; `follow` navigates the same way.
- **`uri:`** is for a location you only have as a string (a notification payload, a CMS
  field). It is a path of this app with the mount prefix, not an external URL. In a debug build a
  `uri:` that no route matches throws when the link builds, saying so: it asks the router above
  it (`GoRouter.configuration.findMatch`), or `RouteLinkScope.match` below. It can't see a segment
  that doesn't parse (`/products/abc`), which only the generated matcher does. `fsp` also warns
  about a `Uri.parse` literal that matches no route when it builds (since 0.7.0, see
  [Checking string paths](cli.md#checking-string-paths)).
- **No `extra`.** An `extra` is not part of the URL, so a link has none. For a route that takes
  one, call `route.go(context, extra: ...)` from the child's own `onTap`.

`RouteLinkScope` sets the defaults for every link below it, once, and needs no generated code:

```dart
MaterialApp.router(
  routerConfig: router,
  builder: (context, child) => RouteLinkScope(
    preload: Preload.intent,       // for links that don't say
    match: AppRoutes.matchUrl,     // lets a `uri:` link preload, and checks it exactly
    child: child!,
  ),
)
```

### Preloading the data behind a link

A link's `preload` starts the data of the page it points at before it is followed, so the page
shows at once instead of `loading.dart`. It starts **every** provider the page reads, the
data of each [section](data.md#section-data) above it and its own, through `route.preload(ref)` (or
`AppRoutes.preload(ref, uri)` for a `uri:` link, given the scope's `match`), and the link owns the
`PrefetchHandle` it gets back.

- `Preload.none` (the default): nothing; the page loads when it is reached.
- `Preload.intent`: when the pointer enters the link, the link or something inside it takes
  focus, or a pointer goes down on it (a touch, before the finger lifts). Held until the link is
  disposed, so coming back to the list is still warm.
- `Preload.visible`: when the link is on screen: inside the view and the viewport of every
  scrollable around it, on a route or tab that is showing. Released when it scrolls out or a page
  covers it, started again when it comes back, and closed when the link is disposed. It is
  checked after a frame in which the link was built, its scrollable moved or its route went
  under another, so a long list costs one comparison per scroll frame for the links it has
  built, and no timer.

What it never does: navigate, run `guard.dart` or `redirect.dart` (a guard runs when the link
is followed; preloading is only the load), keep a failure (a provider that throws closes the
handle, and no page is left with an error nobody asked for), or load twice for repeated
hovering (a link holds one handle, and a provider that several links start is loaded once). A link
that failed to preload tries again on its next intent, but not on every scroll tick of a visible
one. Changing the link's route or `preload` releases what it held.

A link to a [deferred route](#deferred-routes-a-pages-code-on-demand) (since 0.7.0) starts the page's _code_ too, in the same
moment, through the same `route.preload(ref)`; the code, once loaded, stays loaded, so a link
releasing its handle drops the data only.

The same call is there without a widget, for your own queue: `ProductRoute(id: 2).preload(ref)`
and `AppRoutes.preload(ref, uri)` return one `PrefetchHandle`; close it when the lease ends.

**`onPreload`** (since 0.9.0) is for what the page needs that is not a provider, such as the image it shows,
at the size it shows it. It runs with the link's `BuildContext` right after the link starts `route.preload(ref)`:
for `Preload.intent` on the first intent (and on the next one after a failed preload), for `Preload.visible`
each time the link comes back on screen. It is not called when the link preloads nothing (`Preload.none`,
or a `uri:` link no `RouteLinkScope.match` matches). It must return at once, and what it throws is reported
with `FlutterError.reportError` (library `fespalier`, `while running onPreload of a RouteLink to
/products/3`) while the preload goes on. The page's size is known only where there is a `BuildContext`,
which is why this is a callback of the link and not part of `route.preload(ref)`:

```dart
RouteLink(
  to: ProductRoute(id: p.id),
  preload: Preload.intent,
  // The page shows the photo pagePhotoSize wide: warm that size, not the row's.
  onPreload: (context) => ResponsiveImage.precache(context, p.image, width: pagePhotoSize, aspectRatio: 1),
  builder: (context, follow) => ListTile(title: Text(p.name), onTap: follow),
)
```

See [Precaching an image behind a link](responsive-images.md#precaching-an-image-behind-a-link).

`RouteLink` needs the app's `ProviderScope` above it, like every fespalier page, even when it
preloads nothing. It depends on `package:url_launcher` (only its `Link`; nothing is launched,
though pub resolves url_launcher's platform packages).

## Deferred routes: a page's code on demand

_Since 0.7.0._ A Flutter web app is one JavaScript bundle: every page's code is downloaded before the
first frame, however few the visitor opens. Dart can split it: a library imported `deferred as` is
compiled to a file of its own that the browser fetches when `loadLibrary()` is called. fespalier
does that for a route's `page.dart`, and loads the code the way it loads data: when the page is
built, or ahead of time (see [Preloading](#preloading-the-data-behind-a-link)).

**Turn it on.** It is off by default, and a route that isn't deferred generates exactly the code it did
before 0.7.0. For a folder, in its `route.dart`, which covers that folder and everything below it,
the nearest one winning over the parent's and over the pubspec, like
[`remount`](#remounting-a-page-remount):

```dart
// lib/app/checkout/route.dart
const deferred = true;
```

For the whole app, in the pubspec's `fespalier:` section (a `route.dart` says `const deferred = false;`
to opt a folder out, the landing page for one):

```yaml
fespalier:
  deferred: true
```

The value is read from the source when the tree is generated, never imported or run, so it must be
a `true` or `false` literal and declared once; anything else is an error with a code frame, and a
pubspec value that isn't a bool is serde's own error: ``invalid pubspec.yaml: fespalier.deferred: invalid type: string "maybe", expected a boolean at line 3 column 13``. Like
`caseSensitive` it is inherited by `(group)` folders and folders without a page, and needs no page
beside it. `fsp routes` tags such a route `deferred`, `--json` has `"deferred":true` (only there for
a deferred route), `--graph` marks it, and `AppManifest`'s `RouteInfo.deferred` says so at runtime.

**Only `page.dart` is deferred**, the page of a route (a tab layout's own page included). The rest is
needed before a page exists, and stays in the main bundle:

| Stays eager                                    | Why                                                                                                             |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `layout.dart`                                  | It wraps a `Navigator` (a `StatefulNavigationShell` for tabs): a placeholder would unmount them and their state |
| `loading.dart`, `error.dart`                   | They are what shows while the code loads, or when loading it fails                                              |
| `guard.dart`, `redirect.dart`                  | They run synchronously, before any build, and decide before a byte of code is fetched                           |
| `data.dart`, `action.dart`                     | The typed routes, `matchUrl`, `dataAt` and `preload` name their providers synchronously                         |
| `meta.dart`, `transition.dart`, `present.dart` | Used in a `const` list, or build the `Page` itself                                                              |

A `redirect.dart` route has no page, so it is never deferred.

**What shows while it loads.** Navigation completes at once, as ever. The route's `Page` is built,
its transition plays, the layout and the tab bar around it are there, and the page's place shows the
nearest [`loading.dart`](data.md#datadart-a-function-a-selector-or-a-provider) (a centred spinner without one)
until the code arrives. If it can't be fetched (offline, a stale deploy), the nearest `error.dart` shows
with what `loadLibrary()` threw (a `DeferredLoadException` on the web), and its `retry` loads the code again. dart2js already tries a chunk
three times before it gives up. Turning `deferred` on therefore binds the nearest `loading.dart` and
`error.dart` to the route, as `data.dart` does, with the same rule: an inherited view must fit every
route it covers (an `error.dart` that asks for a segment fails the route that has none, and one that
asks for a query parameter adds it to the typed route).

**Once the code is loaded, the page is built synchronously**, with no `Future` and no extra frame:
a second visit, or a visit after a preload, costs nothing. The page's state survives the load.

**Data and code load in parallel.** A deferred page with a `data.dart` starts its code at the first
build, beside the data (`DataView(library: ...)`), and shows the page when both are there; `loading.dart`
covers both waits, `keep_previous` is unchanged, and a data error still gets the data's `retry`.

**Guards run first.** A guard that redirects means the page's code is never requested. Preloading
never runs a guard and never navigates; it may download the code of a guarded page (code, not data),
and the guard still decides when the page is reached. An unparsable segment shows `not_found.dart`,
and loads no code.

**Preloading the code.** It goes with the data:

- `XRoute(...).preload(ref)` (and so a [`RouteLink`](#links-routelink) with `preload`, and
  `AppRoutes.preload(ref, uri)`) also starts the page's code. A route that reads no data returns a
  closed handle; the code, once loaded, stays loaded, so closing a handle only drops the data.
  `AppRoutes.preload` goes through `matchUrl(uri)?.route.preload(ref)` when the app has a deferred
  route. A typed route preloads its own page's code, not the pages `go` stacks under it.
- `AppRoutes.deferred` lists the `DeferredLibrary` of each deferred route, and
  `AppRoutes.loadDeferred()` loads them all, which is the "once the app is idle" strategy: call it
  after the first frame. There is no `const preload = true;`, and no limit on how many load at once
  (each loads once, and the browser dedups).
- `RouteLink` with a `uri:` and a `RouteLinkScope.match` preloads through the matched route's `preload`
  (a hand-built `UrlMatch` whose route doesn't override `preload` no longer preloads its data).

**Platforms.** On the web each deferred page is a `main.dart.js_N.part.js`. Elsewhere the code is in the
binary already, but `loadLibrary()` still takes a turn of the event loop, so a page shows its
`loading.dart` for about a frame on its first visit unless it was preloaded. Load them before
`runApp` there: it costs no I/O, and keeps a deferred page's restorable state working on Android and iOS.

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) await AppRoutes.loadDeferred();
  runApp(const ProviderScope(child: MyApp()));
}
```

Android deferred components (a Play Store feature) are not tried: `loadDeferred` would download all of
them. `--wasm` compiles, and whether it splits is not verified; correctness doesn't depend on it.
`examples/shop` defers `/checkout` and `/products/:id`, and `just web-chunks` builds it for the web,
checks that their strings are in chunks of their own, and holds the build to the budgets in its
pubspec with [`fsp size`](cli.md#web-chunk-sizes-fsp-size), which reports what each chunk costs per route.

**A type declared in a deferred `page.dart` is an error.** The generated file names the types of
segments, query parameters and `extra` outside the page, and Dart can't use a deferred library's
type there (`type_annotation_deferred_class`). An enum (`enum Sort { name, price }`) or an `extra`
class declared in the page's own file is therefore reported, at the page, with what to do:

```text
error: `Sort` is declared in this page.dart, which is deferred, and the generated code names it outside the page (as the type of a segment, a query parameter or an `extra`): Dart can't use a deferred library's types there. Move `Sort` to a file of its own and import it here, or say `const deferred = false;` in this folder's route.dart
```

Move the type to a file of its own (`lib/models/sort.dart`) and import it in the page ([enum segments](routing.md#enum-segments) can be declared in any file the page imports), or leave
that folder eager. A type
declared in a page that is _not_ deferred is fine for a deferred child.

**Testing.** A deferred library's `loadLibrary()` completes only on the real event loop, which a
widget test's `pump` never runs, so a test would show `loading.dart` for ever or end with "A Timer is
still pending". `pumpRouter` therefore loads every deferred route's code first, in `runAsync`, and a
deferred page is in the first settled frame like an eager one. A test that pumps a router of its own
does the same itself, before `pumpWidget`:

```dart
await tester.runAsync(AppRoutes.loadDeferred);
```

Forgetting it is a `FlutterError` in a debug build, not a hang: _"The code of products/$id/page.dart
is not loaded, and a widget test can't load it while it pumps."_ The loading state of a real deferred
page can't be seen in a widget test; test your own `loading.dart`, or
`DeferredLibrary(() => completer.future, 'x/page.dart', loadsInFakeAsync: true)` with a `DeferredView`
(that is how the package tests it).

**Not built:** deferring a `layout.dart`, a `const preload = true;` strategy, a cap on parallel
loads, and a `deferred: auto` mode (dart2js already makes a chunk of each deferred import, and moves
shared code into shared chunks: `deferred: true` in the pubspec and `const deferred = false;` on
the landing page is "everything split"). Don't defer the landing page: it would show `loading.dart`
before its first paint.

`packages/fespalier/lib/src/deferred.dart` has the runtime (`DeferredLibrary`, `DeferredView`);
`examples/shop/test/deferred_test.dart` and `packages/fespalier/test/deferred_test.dart` test it.
