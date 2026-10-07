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

_Since 0.5.0._ A filtered, sorted, paginated list that keeps its state in the query is a link someone can send, and back and forward move between its views. Every typed route has two ways in and one way to change a part of it:

```dart
final route = SearchRoute.of(context);          // the typed route at the current location
final maybe = SearchRoute.maybeOf(context);     // null instead of throwing

route.copyWith(page: (route.page ?? 1) + 1).go(context);          // a history entry
route.copyWith(sort: Sort.name, page: null).go(context);           // null clears a query parameter
SearchRoute(q: 'ap').copyWith(page: 2).location;                   // '/search?q=ap&page=2': a value, no widget
```

- **`XRoute.of(context)`** parses the location the widget belongs to with the parsers [`AppRoutes.match`](data.md#from-a-location-to-its-data) uses (it calls `AppRoutes.matchUrl`): the mount point is taken off, a [localized spelling](routing.md#localized-paths) is the route it spells, and the [case setting](routing.md#case-and-trailing-slashes), [enums](routing.md#enum-segments), lists and [catch-alls](routing.md#catch-all-segments) read as they do for the page. It throws a `StateError` naming the location when it is another route; `XRoute.maybeOf(context)` returns `null`. Use it in a widget below the page that wasn't handed the parameters; the page itself has them as constructor arguments and rebuilds when they change. (A `const` route stays `const`: `of` and `copyWith` are members, not constructor parameters.)
- **Which location.** `GoRouterState.of(context)`'s: the route around the widget, not whichever page is on top. A page reads the part of the URL its own route matched, with the URL's query, so `/products/42?ref=mail` leaves the page of `/products` below it reading `ProductsRoute(ref: 'mail')`; a page under a pushed one and a tab that is built but not shown (`preload`) read their own. A layout (a shell, a tab layout) is above any one page and reads the whole location. Outside any route (`MaterialApp(home: ...)`) `of` throws go_router's `GoError` and `maybeOf` returns `null`. A widget that calls it rebuilds when its route's state changes, as with `GoRouterState.of`; call it in `build` or in a handler of a mounted widget.
- **`copyWith`** takes every segment and every query parameter of the route, by name and with the field's own type.
  - A parameter left out keeps its value; **`null` clears an optional query parameter** (`page: null` leaves `?page=` out of the location). It tells `null` from omitted because it is a getter of a function type ([why](faq.md#why-copywith-is-a-getter-of-a-function-type)).
  - A segment, and a `List` (a repeated query parameter or a catch-all), is not nullable, so `copyWith(id: null)` doesn't compile: clear a list with an empty one (`tags: const []`).
  - It returns the same route class, so `.go`, `.push`, `.replace` and `.location` follow.
  - What isn't a parameter isn't carried: give an `extra` again to `go(context, extra: ...)`, and choose the localized spelling where the route is used (`go(context, locale: 'de')`).
- **`go`, `push`, `replace`.** `go` follows the URL: on the web it adds a history entry, and back and forward restore each view.
  - `replace` (since 0.6.0) shows its location in the address bar and replaces the history entry instead of adding one, so it is the one for a change that shouldn't pile up in the back stack (typing in a search box). Over a `push`ed page it is go_router's own: it swaps that page and keeps the stack below it. Otherwise it is `go` inside Flutter's `Router.neglect`: the stack becomes the one the new location has by itself, and a page with the same path template keeps its state.
  - `push` stays out of the address bar and the history unless `push_updates_url: true` is set in [the pubspec](configuration.md#the-fespalier-section) (since 0.6.0).
- **`pushReplacement`** (since 0.7.0) is go_router's own, typed like `push`: the page on top leaves and a new one is pushed, with a new page key, and the future completes with what that page pops with. Use it where `replace` is wrong because the page's state or transition must not carry over: a sheet that hands over to a full page, or the reverse. The replaced page's own future never completes, and when it was the only page, neither does this one (go_router's behaviour). Both take `locale:`, and `extra:` where the route has one.
- **Reserved names.** `of`, `maybeOf` and `copyWith` can't be segment or query names (see [Typed helpers on the route](data.md#typed-helpers-on-the-route)).
- Everything here is synchronous and uses no timer or microtask.
- **The page's own state.** A `copyWith` that only changes query parameters keeps the page and its widget state under `never` (the default) and `onSegments`, and starts the page again under `onLocation`. To keep that state across `page: 2` and still start fresh for another product, say `Remount.onSegments`: see [Remounting a page](#remounting-a-page-remount).

## Remounting a page: `remount`

_Since 0.6.0._ go_router keys a page by its path template, so `/products/1` to `/products/2` is the same page: its widget is built again with the new `id`, but its `State` (a scroll position, a text field, a hook's `useState`) lives on. Some apps want that, others want a fresh page, so it is a setting. `Remount` is an enum fespalier exports, with three values:

| Value                 | The page starts again (a fresh state) when             | It keeps its state when            |
| --------------------- | ------------------------------------------------------ | ---------------------------------- |
| `never` (the default) | never                                                  | anything changes in the URL        |
| `onSegments`          | the value of a segment changes (`/products/1` to `/2`) | only the query changes (`?page=2`) |
| `onLocation`          | anything changes in the location, the query included   | the location is the same           |

`onSegments` is the one that fits [the URL as state](#the-url-as-state-of-and-copywith): the page keeps its state across `XRoute.of(context).copyWith(page: 2)`, and starts again on another product.

**Where to say it.** For the whole app, in the pubspec's `fespalier:` section (`never`, `on_segments` or `on_location`):

```yaml
fespalier:
  remount: on_segments
```

For a folder, in its `route.dart`, which covers that folder and everything below it:

```dart
// lib/app/products/route.dart
import 'package:fespalier/fespalier.dart';

const remount = Remount.onSegments;
```

- It must be `const`, one of `Remount.never`, `Remount.onSegments` and `Remount.onLocation` written out (an import prefix, `fsp.Remount.onSegments`, is fine), and declared once. Anything else is an error with a code frame, and so is a pubspec value that isn't one of the three (the message lists them). The other rules of `route.dart` constants are [in Configuration](configuration.md#per-folder-settings-routedart); a folder can say `Remount.never` to go back to the default under a parent that remounts.
- `fsp routes` tags such a page `remount`, and `--json` says which in a `remount` key.

**What it keys.** Only the page of a route: the generated code gives it a key that changes with the URL, in place of go_router's `state.pageKey`.

- `onSegments`: the template plus the values of the route's own path parameters, those of the folders above it included (`/teams/:teamId/members/:member` starts again when either changes), as the URL spells them. The static parts of the path (their [case](routing.md#case-and-trailing-slashes), a [localized spelling](routing.md#localized-paths)) are not in it. A route with no segment has nothing to watch, and is generated as if it were `never`.
- `onLocation`: the template, the path matched down to this route and the whole query. The fragment (`#top`) is not in it. A page below which another is pushed (`/orders/1` under `/orders/1/refund`) keeps its key and state, because the path is the route's own, not the whole location's.

A layout is not remounted, whatever its folder says: its page is keyed by its folder so that it and its [sections](data.md#section-data) outlive a change of the URL (the pages inside it start again by their own `remount`). Give a widget in a layout a `ValueKey` of your own if it should start again.

**A new key is a new page.** go_router treats a page with another key as another page: the navigator replaces the old page with the new one, so the page's transition may play, and the old page leaves with its own.

- How it looks is the page's [`transition.dart`](layouts.md#transitions) (or [`present.dart`](#presentdart-a-page-of-your-own)), which receives the key as its `LocalKey key` parameter. Pass it on to the `Page` you build, as `Transitions.fade` does.
- A `transition.dart` that takes no key can't give the new page one, so `remount` has nothing to act on there, and the generator warns about it.
- Without a `transition.dart` the page is a Material page, or a Cupertino one inside a `CupertinoApp`, built like a layout's page is (`remountPage`).
- Use `Transitions.none` for a page that should start again without animating.

**Not what it is for.** It restarts the page's widgets, not its data: a `data.dart` provider is keyed by the segments and the query already, and reloads (see [Retries and reloads](data.md#retries-and-reloads)) whether the page remounts or not. And it does not change which route matches or what `XRoute.of(context)` reads.

## Typed `extra`

go_router can carry an object with a navigation, `context.go(location, extra: product)`, that isn't part of the URL. A page asks for it with a parameter called `extra`, and the typed route takes it as an optional argument:

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

The parameter **must be nullable** (`Note?`, `Object?` or `dynamic`; anything else is an error at that parameter). The object isn't in the URL, so a deep link, a page opened from `context.go('/notes/3')` and (without an [`extraCodec`](#restoring-extra-on-the-web)) a reload or a restored state all get `null`: build the page from the URL (`id`) and treat `extra` as a shortcut, not the source of truth. An object of the wrong type passed around the typed route (a plain `context.go(location, extra: …)`) is an assertion error in debug builds and reads as `null` in release builds.

`extra` is a reserved name: a segment can't be called `extra`, and a query parameter of that name is the extra, not `?extra=`. The generated file names the type for the typed arguments by importing it, `show`ing that name, from each of the file's own imports (a library that doesn't export it is ignored; a type declared in the file itself, or under an import prefix, is found too), so the type must be reachable from those imports. The built-in `dart:core` types need nothing.

**Layouts, guards and redirects take it too.** A `layout.dart`, a `guard.dart` or a `redirect.dart` can ask for `extra` the same way (a nullable type; a guard and a redirect take it as a named parameter). Each gets the extra of the location it is at now, `state.extra`:

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

A layout or a guard sees the extra of _every_ route it covers, so its type has to fit theirs, or it's an error at its parameter, with a code frame that lists the routes:

- A guard or layout takes `Object?` (or `dynamic`) to accept anything, or **the type of the routes it covers** (`Note?` above pages that take `Note?`). Nullability aside, the names have to match. A route that takes no extra puts no condition on it.
- So a layout above routes with different extra types must take `Object?`; otherwise the routes that don't fit are listed:

  ```text
  error: `extra` is `Note?` here, but the routes it covers take other types: `/notes/:id/print`
         (notes/$id/print/page.dart takes `Receipt?`); a layout sees the extra of every route it
         covers, so declare it as `Object?` to accept any of them, or as their type when they share one
    ┌─ lib/app/notes/layout.dart:3:53
  ```

  A page's or redirect's own type decides for a route; on a route without one, the guards and layouts above it must agree with each other. A layout isn't compared with a `redirect.dart` route below it, which never shows it.

- A route that takes no extra of its own gets the type its guards and layouts agree on, so `NoteRoute(...).go(context, extra: note)` is typed even if the page ignores it. `Object?` says nothing about a type: it adds no typed argument.
- **A wrong type never crashes them.** A layout, a guard or a redirect sees extras meant for other routes, so an object that isn't a `Note` reads as `null` (`extraOrNull`), and so does an extra that isn't there. Only a page asserts, as above.

### Restoring `extra` on the web

go_router keeps a navigation's `extra` for the browser's history and for state restoration, but can only save JSON. Without help, an object with a `toJson()` comes back as the `Map` that `jsonEncode` made of it, and any other object is dropped (go_router logs a warning). Neither is your type, so a page that asks for a `Note?` gets `null` in release builds and, for the `Map`, an assertion in debug builds. To get the object back, give the router an `extraCodec`.

Put a top-level `extraCodec` in `lib/app/extra_codec.dart`, at the root of the app folder (a `const`, a `final` or a getter; `fsp` only looks for the name). The generated `AppRoutes.router()` passes it as `GoRouter(extraCodec: …)`:

```dart
// lib/app/extra_codec.dart
import 'package:fespalier/fespalier.dart';

final extraCodec = ExtraCodec({
  Note: (toJson: (Note n) => n.toJson(), fromJson: Note.fromJson),
  Mode: (toJson: (Mode m) => m.name, fromJson: Mode.values.byName),
});
```

`ExtraCodec` takes each type and how it becomes JSON and back (annotate the parameter of `toJson`; a constructor tear-off does for `fromJson`), and saves an object under its type's name. `null`, strings, numbers, booleans and plain JSON lists and maps need no entry.

It never breaks navigation: an object whose type isn't registered is saved as `null`, and saved data that no longer reads (the type was removed, or `fromJson` throws) comes back as `null`, so a page falls back to what the URL says. Pass `strict: true` to throw instead, in a test that checks you registered every type.

- The type is looked up by its exact runtime type: register each subclass of a sealed class.
- The name is `Type.toString()`, which a release build for the web minifies (stable within a build, different in the next). To keep saved data readable across deployments, name the types: `ExtraCodec({...}, names: {Note: 'note'})`.
- Write your own `Codec<Object?, Object?>` instead if you like (`const extraCodec = MyCodec();`).
- `AppRoutes.mount()` doesn't take it: a router you build yourself passes `extraCodec: extraCodec` (imported from that file) to `GoRouter`. A router restores only what it is given a `restorationScopeId` for (see [State restoration](layouts.md#state-restoration)).
- `extra_codec.dart` in a subfolder is a warning, and a file without an `extraCodec` is an error.

## The root navigator (`navigator.dart`)

A route's URL and the navigator it renders on are two decisions. A tab layout puts every route in its folder on a tab's navigator, under the navigation bar. `navigator.dart` puts a folder on the **root** navigator instead, above every layout and tab bar, without moving its URL:

```dart
// lib/app/(tabs)/profile/edit/navigator.dart
const navigator = RouteNavigator.root;
```

`/profile/edit` is still under `/profile` (a deep link builds the Profile tab beneath it, and back returns to it, with its state), and the page covers the whole screen. The declaration applies to its folder's routes and to **every folder below it**, and the nearest one wins, like `transition.dart`; a page-less `(group)` folder can hold it too, for the routes inside. `fsp gen` emits `parentNavigatorKey: rootNavigatorKey` on the route and on all its descendants (go*router puts a route on its enclosing shell's navigator unless told otherwise, so a child pushed from the page would land \_under* it), and the route table marks them `(root)`.

The generated file owns the key:

- `AppRoutes.rootNavigatorKey` is a `GlobalKey<NavigatorState>` the app can read: the last `router()` or `mount()` call's (a call given no key makes a fresh one rather than keeping an earlier call's, since 0.5.0).
- `AppRoutes.router(navigatorKey: …)` uses one you supply.
- `AppRoutes.mount(at:, navigatorKey: …)` takes the **host** `GoRouter`'s own key, since a `parentNavigatorKey` must name an ancestor navigator.

Rules:

- `fsp` reads the file from the source, like `tabs`: a `const navigator` that is `RouteNavigator.root` or `RouteNavigator.shell`, spelled out; anything else is an error at it.
- **A layout is a navigator of its own.** A `layout.dart` below a root folder becomes a `ShellRoute(parentNavigatorKey: rootNavigatorKey, …)` (or the `StatefulShellRoute`); the routes inside it sit on its own navigator, since go_router doesn't allow a key other than the shell's there. Below a layout nothing is inherited, and `RouteNavigator.shell` is how a folder says so explicitly. Below a root route with **no** layout in between, `.shell` is an error: go_router only lets a descendant use the root navigator or a navigator above it.
- **A root route can't be a direct child of a shell.** go_router lifts a route out of its shell only from below another route, so a root route that is the first route of a tab, or sits beside others directly in a layout, is an error (put it below a `page.dart` that stays in the layout, or move its folder out of the layout's folder).
- The typed route is unchanged: `EditProfileRoute().push(context)` and `.go(context)` as before.

## `present.dart`: a page of your own

`present.dart` builds **this route's own `Page`**. It is for a sheet (or a dialog, or any page class the app owns) with a URL: `/products/:id/buy` opens a sheet over `/products/:id`, from a link or a deep link.

```dart
// lib/app/products/$productId/buy/present.dart
Page<void> present(LocalKey key, Widget child) => SheetPage(key: key, child: child);
```

It is bound like `transition.dart` (`key`, `child`, `state`), and what it returns is used **verbatim**: fespalier adds no scrim, handle or shape, and ships no sheet widget. It does not name the page either: pass `name: Transitions.pageName` (since 0.9.0, the route's pattern) for an observer to see it. Unlike `transition.dart`:

- it applies to **its own folder only**: a folder below keeps the nearest `transition.dart` for its own page;
- it puts the route on the **root navigator**, over a tab bar and any `layout.dart`, and its descendants too (the [`navigator.dart`](#the-root-navigator-navigatordart) rules, so a child of a sheet renders above it, never under it, and go_router never builds the shell twice). A `navigator.dart` in the same folder overrides that (`RouteNavigator.shell` keeps a sheet in a tab);
- it needs a `page.dart` (a warning and no effect otherwise), and, to have a parent underneath on a deep link, the sheet's folder should sit below the parent page's folder.

The route table marks it `(present, root)`, and the manifest's `presentation` is `RoutePresentation.custom` (fespalier can't know it is a sheet: say so in a `meta.dart` if you want to).

## Leaving a page: `leave.dart`

Since 0.11.0, a `leave.dart` is asked before its folder's page goes: a form with unsaved changes, a call in progress. It returns `true` to let the page go and `false` to keep it, and it asks however the app does (no dialog is assumed). It is go_router's `GoRoute.onExit`, written for you, with a back gesture that asks too.

```dart
// lib/app/orders/$id/edit/leave.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// Asked before /orders/:id/edit goes. True lets it go; false keeps it.
LeaveResult leave(BuildContext context, Ref ref, {required int id, required PageLeave page}) async {
  if (!page.isDirty) return true; // stays sync when you return a bool directly
  final ok = await showModalBottomSheet<bool>(context: context, builder: (c) => DiscardSheet());
  return ok ?? false;
}
```

**The function.** `leave`, a public top-level function that returns `LeaveResult` (`FutureOr<bool>`, so the file needs no `dart:async`); `FutureOr<bool>`, `Future<bool>` and `bool` are accepted too. Other functions in the file are helpers and are ignored.

**The parameters.** Positional, each optional and in this order: `BuildContext context`, then `Ref ref`. The context is the **root navigator's** (go_router hands it to `onExit`, not the page's), so `showModalBottomSheet(context: context)` opens above every layout and tab bar. The `Ref` is a throwaway provider's, kept open until the answer is in, so it is still valid after an `await`: `ref.read` what you need, and do not `ref.watch` (a prompt must not run twice, so the first run's answer stands, and a watched provider that changes disposes that run's `Ref`). Named, bound like a [guard's](guards.md): the folder's segments and those above it, typed (`required int id`); query parameters, optional and nullable (they belong to the folder's route); `Uri uri`; `extra`, typed, as a guard takes it; and `PageLeave page`, by type and name. `WidgetRef`, `ProviderContainer` and `TypedLocation` are errors.

**What `leave()` learns: `PageLeave`.** `page.state` is the `GoRouterState` of the page that is going. `page.isDirty` says whether anything on the page would be lost (any `LeaveSource` it registered is dirty; a [`useForm`](forms.md#leaving-with-unsaved-changes) of `fespalier_forms` registers its form by itself, nothing else does, so a page that registers none is always clean), `page.canKeep` whether one can save its input as a draft, `page.keep()` makes each save its draft and `page.discard()` makes each drop it. A page with nothing registered is clean and cannot keep.

**A folder's own page only.** A `leave.dart` is not inherited: it applies to its folder's `GoRoute` and nothing else, because go_router already asks a parent's `onExit` when the parent's own match exits:

- `/orders/1/edit` to `/orders/1` asks `edit` only;
- `/orders/1/edit` to `/home` asks `edit`, then `$id`;
- a [`nest = false`](routing.md#a-sibling-with-a-compound-path) sibling leaves its parent's match, so the parent's `leave.dart` is asked too.

The folder needs a `page.dart`: a layout's shell has no `onExit` in go_router, so a `leave.dart` beside a `layout.dart` alone is an error (put one beside each page that needs it), and so is one in a `redirect.dart` folder, which never stays on screen.

**What is asked.** (`leave.dart` is imported eagerly, never `deferred`, so whatever it imports, a deferred page's own library included, is part of the main chunk: keep it to what the question needs.)

- **Asked:**
  - `go`, `replace`, `pushReplacement`, `pop`, `context.pop` and `Navigator.pop` of the page;
  - Android back (through `PopScope` and `GoRouter.pop`, or go_router's root fallback, where `true` closes the app);
  - the web's back and forward (refused: the address bar is reset to the page, a new history entry, forward history lost);
  - a guard's refresh or redirect, **including a sign-out redirect**: check auth in `leave()`, or wrap sign-out in `leaveWithoutAsking`;
  - go_router's `onEnter` (the adapters', since 0.11.0) and guards run first at parse time; `onExit` runs after, in the delegate;
  - leaving a tab layout, for the **active** tab's pages only.
- **Not asked:**
  - a tab switch (fespalier parks; go_router would ask), unless a route it reaches that the page is not already under has a `redirect:` of its own (a `guard.dart` in that tab's own folder): that redirect may take the navigation out of the tab layout, so the page is asked. A guard of the tabs' folder, or above it, is emitted on the tab shell (since 0.11.0), so it never makes a switch ask. The price: if such a guard's answer changes at the switch itself, without a refresh (it reads state that is not reactive, such as an expired token, or decides on the `uri`), and it redirects out of the tab layout, the page is dropped without being asked. A hand-written top-level `redirect:` on the router cannot be seen either;
  - a parked tab's pages when the whole layout leaves (use drafts);
  - a query-only change (`copyWith(page: 2)`), nor `replace` of a pushed page with itself at another query;
  - a dialog or sheet (a pageless route) on top;
  - `refresh()` with the same match list;
  - a redirect.dart route;
  - layouts;
  - an imperative `Navigator.push` or replace outside go_router;
  - process kill, hot restart, `router.dispose()`;
  - the page's own `PopScope(canPop: false)`, which wins for system back.
- **Known gap:** on go_router 17.0 to 17.3 (Flutter below 3.38), popping a whole `ShellRoute` page off the root navigator skips the leaf's `leave()` (go_router fixed it in 17.4.0).

`/c/1` to `/c/2` is asked, whatever [`remount`](#remounting-a-page-remount) says: it is another page instance. A query-only change is the same one.

**The answer.**

- **Synchronous stays synchronous.** A `leave()` that returns a `bool` makes no `Future` and no microtask of its own.
- **One prompt at a time.** While a prompt for a page is open, a second ask of the same page (a double tap on back, a second `go`) waits for it and `leave()` does not run again. The first answer acts on the page; a second ask answers `true` only if the page is still there after that, so a double pop completes once and a back that joined a `go`'s prompt never closes the app. A `leave()` whose `Future` never completes holds every later ask of that page: complete it. A newer `go` that joins the prompt of an earlier one is refused once the earlier one has taken the page away (the first navigation wins).
- **Errors fail open.** A `leave()` that throws, now or in its `Future`, is reported with `FlutterError.reportError` (library `fespalier`, context `while running leave() of orders/$id/edit/leave.dart`) and the page goes: a broken `leave()` never traps the user. In a widget test that fails the test.
- **A segment that does not parse** shows not-found, so there is nothing to ask and the page goes; the not-found page is not wrapped, so it keeps the iOS swipe.
- **A pop is judged by where the router is going.** While an asynchronously guarded `go` is still being parsed, a pop of a page in a tab is compared with that destination and may be taken for a tab switch.

**Skipping the question: `leaveWithoutAsking`.**

A navigation the user has already decided, such as signing out, should not ask:

```dart
await leaveWithoutAsking(router, () => ref.read(auth).signOut());
```

`navigate` may be asynchronous: no page asks while it runs and while the `Future` it returns is pending. `leaveWithoutAsking` always returns a `Future`, which completes when its window has closed: it waits for what fespalier's own guards settle after `navigate` (the container runs what was scheduled, an asynchronous guard still being evaluated is awaited) and lets through the `refresh` a guard asks for in that time, so signing out a session that a `guard.dart` watches ends at the login page without a question. That pass is kept until the router commits what the refresh set going, however long a redirect on the way (an async `redirect.dart` at the destination, say) takes, and ends early at the next navigation of any other kind; a guard that never answers therefore keeps it until the next navigation, and a pop in that time is not asked. If `navigate` requested a navigation that the router has not committed by then, that one is let through too, while the route information is still the one it left, until the first commit (a one-shot listener). It never covers a pop after the window, nor a `navigate` that requests nothing or a request that commits nothing (a `go` to where you are): a sign-out that fails leaves every page asking again. A hand-written top-level `redirect:` that settles later is not waited for. `GoRouter.of(context)` gives the router.

**The back gestures.**

Every generated page of a folder with a `leave.dart` is wrapped in `leaveScope`, which holds the page's sources and a `PopScope`. When the page's route can pop (a pushed page), the `PopScope` lets a pop through only if the page has at least one source and every source is clean; otherwise the back is turned into `GoRouter.pop`, which asks `leave()`. So:

- **The iOS edge swipe** is off while the page has no source or a source is dirty, because the gesture animates the page away before go_router can refuse. It works when every source is clean, and the pop then asks `leave()` like any other.
- **Android's predictive back** shows no preview while the `PopScope` blocks.
- **Android back** always goes through `leave()`: through the `PopScope` on a pushed page, and, on the bottom page of a navigator, through go_router's own fallback, where `true` lets the system close the app and `false` keeps it.

**What a page registers: `LeaveSource`.**

`LeaveSource` is what a form, or anything else that holds input, registers to be asked about: `isDirty`, `canKeep`, `keep()`, `discard()`, and it is a `Listenable` (the `PopScope` is rebuilt when it notifies). A widget under the page registers it in the page's scope, safely during `build`:

```dart
final unregister = LeaveScope.maybeOf(context)?.register(source); // null in a page without a leave.dart
```

Core knows nothing of forms: it is the `fespalier_forms` package that makes its forms sources (since 0.11.0): a `useForm` under a page with a `leave.dart` registers its form, and `leaveIfClean(context, ref, page)` is the whole `leave()` that asks in a bottom sheet and keeps or drops the draft (see [Leaving with unsaved changes](forms.md#leaving-with-unsaved-changes)). Anything else that holds input registers its own, as `examples/features` does for its new-doc page.

A source with somewhere to go back to inside the page (a step of a multi-page form) can take the system back itself: `LeaveScope.maybeOf(context)?.onBack(() => handled)` registers a handler that runs, newest first, on Android's back and `Navigator.maybePop`; the first that returns `true` has handled it, and the page is not popped and `leave()` is not asked. It is consulted where the page's `PopScope` is, so not on the first page of a navigator (go_router's own fallback asks `leave()` there). While a handler is registered the iOS swipe is off.

**Diagnostics and the scaffold.**

`fsp new 'orders/[id]/edit' --leave` writes the file. Each error says what to change: the function is missing or returns the wrong type, the folder has no `page.dart` or has a `redirect.dart`, a `WidgetRef` or `ProviderContainer` is taken, the positional parameters are not `context` then `ref`, or `PageLeave` is not called `page`.

## Links: `RouteLink`

`RouteLink` (since 0.5.0) is a link to a route: a real `<a href>` on the web, a plain widget everywhere else, and a click that goes through go_router either way.

```dart
RouteLink(
  to: ProductRoute(id: p.id),     // any typed route; or `uri: Uri.parse('/products/2')`
  preload: Preload.intent,        // none (default) | intent | visible
  onPreload: (context) => ...,    // runs when the preload starts: what else the page needs (since 0.9.0)
  method: LinkMethod.go,          // go (default) | push | replace
  builder: (context, follow) => ListTile(title: Text(p.name), onTap: follow),
)
```

`builder` gets `follow`, which navigates; give it to the child's `onTap` or `onPressed`. The child is exposed to accessibility services as a link with its URL, and `const RouteLink(...)` works when the route and the builder are constant.

- **On the web** it is built on `url_launcher`'s `Link`, which lays an invisible anchor over the child. The browser shows the URL in its status bar, the context menu offers "open in a new tab", and a middle click, or a click with Ctrl, Cmd, Shift or Alt, opens it in a new tab or window.
  - A plain click or a keyboard activation never reaches the anchor: `follow` calls `GoRouter.go`, `push` or `replace` (the `method`), the page doesn't reload, and the anchor's own navigation is cancelled. With `method: LinkMethod.push` a plain click pushes and a Ctrl-click opens a tab.
  - The `href` is the route's `location`, so it carries the mount prefix (`AppRoutes.mount(at: '/shop')` gives `/shop/products/2`) and, with `locale: 'fr'`, the localized spelling `locationFor('fr')` writes. Under a hash URL strategy the browser prefixes it with `#`, as for any link.
- **Elsewhere** there is no anchor; `follow` navigates the same way.
- **`uri:`** is for a location you only have as a string (a notification payload, a CMS field). It is a path of this app with the mount prefix, not an external URL. In a debug build a `uri:` that no route matches throws when the link builds: it asks the router above it (`GoRouter.configuration.findMatch`), or `RouteLinkScope.match` below. It can't see a segment that doesn't parse (`/products/abc`), which only the generated matcher does. `fsp` also warns about a `Uri.parse` literal that matches no route (since 0.7.0, see [Checking string paths](cli.md#checking-string-paths)).
- **No `extra`.** An `extra` is not part of the URL, so a link has none. For a route that takes one, call `route.go(context, extra: ...)` from the child's own `onTap`.

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

A link's `preload` starts the data of the page it points at before it is followed, so the page shows at once instead of `loading.dart`. It starts **every** provider the page reads, the data of each [section](data.md#section-data) above it and its own, through `route.preload(ref)` (or `AppRoutes.preload(ref, uri)` for a `uri:` link, given the scope's `match`), and the link owns the `PrefetchHandle` it gets back.

- `Preload.none` (the default): nothing; the page loads when it is reached.
- `Preload.intent`: when the pointer enters the link, the link or something inside it takes focus, or a pointer goes down on it (a touch, before the finger lifts). Held until the link is disposed, so coming back to the list is still warm.
- `Preload.visible`: when the link is on screen: inside the view and the viewport of every scrollable around it, on a route or tab that is showing. Released when it scrolls out or a page covers it, started again when it comes back, and closed when the link is disposed. It is checked after a frame in which the link was built, its scrollable moved or its route went under another, so a long list costs one comparison per scroll frame for the links it has built, and no timer.

What it never does:

- navigate, or run `guard.dart` or `redirect.dart` (a guard runs when the link is followed; preloading is only the load);
- keep a failure (a provider that throws closes the handle, so no page is left with an error nobody asked for);
- load twice for repeated hovering (a link holds one handle, and a provider that several links start is loaded once).

A link that failed to preload tries again on its next intent, but not on every scroll tick of a visible one. Changing the link's route or `preload` releases what it held.

A link to a [deferred route](#deferred-routes-a-pages-code-on-demand) (since 0.7.0) starts the page's _code_ too, through the same `route.preload(ref)`; the code, once loaded, stays loaded, so a link releasing its handle drops the data only. The same call is there without a widget, for your own queue: `ProductRoute(id: 2).preload(ref)` and `AppRoutes.preload(ref, uri)` return one `PrefetchHandle`; close it when the lease ends.

**`onPreload`** (since 0.9.0) is for what the page needs that is not a provider, such as the image it shows, at the size it shows it. The page's size is known only where there is a `BuildContext`, which is why this is a callback of the link and not part of `route.preload(ref)`.

- It runs with the link's `BuildContext` right after the link starts `route.preload(ref)`: for `Preload.intent` on the first intent (and on the next one after a failed preload), for `Preload.visible` each time the link comes back on screen.
- It is not called when the link preloads nothing (`Preload.none`, or a `uri:` link no `RouteLinkScope.match` matches).
- It must return at once. What it throws is reported with `FlutterError.reportError` (library `fespalier`, `while running onPreload of a RouteLink to /products/3`) while the preload goes on.

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

`RouteLink` needs the app's `ProviderScope` above it, like every fespalier page, even when it preloads nothing. It depends on `package:url_launcher` (only its `Link`; nothing is launched, though pub resolves url_launcher's platform packages).

## Opening the app: launches and platform links

_Since 0.11.0._ Two things start a navigation that the app's own code did not: a package that knows where the app was
opened from (a notification tap that cold-started it, a home-screen shortcut), and the platform handing over a link
(an App Link, a Universal Link, a custom scheme).

**A launch.** An adapter's `launch()` answers an `InboundLaunch`:

```dart
InboundLaunch('/orders/42', source: NavigationSource.notification);
InboundLaunch.to(OrderRoute(id: 42), source: NavigationSource.shortcut, extra: payload);
```

`launchRouter(launch, (launch) => GoRouter(...), links: true)` builds the router. `make` receives the launch that applies
(null on the web, where the address bar is the launch and a launch is never used). A launch wins over the platform's
initial route (go_router lets a cold-start deep link beat `initialLocation`, unless `overridePlatformDefaultLocation` is
set, which a launch sets) and the first navigation is marked with `launch.source`.

**A platform link.** With `links: true` (an app with telemetry or adapters), `launchRouter` registers one binding
observer before go_router's provider does, launch or not. Each link the running app receives is marked
`NavigationSource.link`, and so is a deep link in the platform's initial route; an in-app `go` to the same location is
not. Links are matched the way go_router reads them (a full URL, a trailing slash or none). The observer only stores the
location: no timer, no frame, no listener on the router. An app with neither telemetry nor adapters adds nothing, and a
router made with `links: false` is never marked. Never on the web.

- **Android** hands a cold-start link to Flutter as the initial route, so it is the router's first navigation
  (`InboundNavigation.initial`), marked `link`.
- **iOS** delivers the link after the first frame, as a link received while running: the router first shows
  `initialLocation` (or the launch), and the link follows as a warm navigation, not `initial`. An adapter cannot rewrite it
  in `launch()`; `onEnter` sees it.
- A host that drives `NavigationChannel.pushRoute` (add-to-app) is marked `link` too.

An adapter's `onEnter` sees the same mark as `InboundNavigation.source`. Any `onEnter` makes go_router parse every
navigation asynchronously and applies its redirect limit to each. `InboundNavigation.initial` is true when go_router has no
route yet, and that navigation must not be blocked (fespalier allows it and reports it).

**Generated.** `AppRoutes.router(launch:)` calls `launchRouter` for you: `launch` is the `InboundLaunch` the app was
opened with (null: none), the router starts at `launch.location` with `launch.extra` over the platform's initial route,
and `links: true` is passed when the app has `telemetry: true` or `adapters:`. The generated main asks
`AppAdapters.launch()` once, after `beforeRun()` and before the router exists, and passes the answer to
`AppRoutes.router(launch: AppMain.launch)`; with `main: manual` your `main()` does the same
(`final launch = await AppAdapters.launch();`, see [With `main: manual`](adapters.md#with-main-manual-appadapters)). An
`app.dart` `router()` that builds the router itself passes `launch: AppMain.launch` on, or `fsp` warns (see
[Adapters](adapters.md)). `launch:` is ignored on the web.

With adapters, `AppRoutes.router` also passes `onEnter: AppRoutes.onEnter`, which forwards to the adapters' `onEnter`
in the pubspec's order; an app that builds a `GoRouter` of its own passes `onEnter: AppRoutes.onEnter` itself.
Without adapters there is no `AppRoutes.onEnter`, and go_router keeps its simplest code path. **Any `onEnter`, this one
included, makes go_router parse every navigation asynchronously and apply its redirect limit to all of them**, so an app
with adapters that has none with an `onEnter` to offer pays that for nothing: leave `adapters:` for the packages you use.

## Deferred routes: a page's code on demand

_Since 0.7.0._ A Flutter web app is one JavaScript bundle: every page's code is downloaded before the first frame. Dart can split it: a library imported `deferred as` is compiled to a file of its own that the browser fetches when `loadLibrary()` is called. fespalier does that for a route's `page.dart`, and loads the code the way it loads data: when the page is built, or ahead of time (see [Preloading](#preloading-the-data-behind-a-link)).

**Turn it on.** It is off by default. For a folder, in its `route.dart`, which covers that folder and everything below it:

```dart
// lib/app/checkout/route.dart
const deferred = true;
```

For the whole app, in the pubspec's `fespalier:` section (a `route.dart` says `const deferred = false;` to opt a folder out, the landing page for one):

```yaml
fespalier:
  deferred: true
```

The value is read from the source, so it must be a `true` or `false` literal and declared once; anything else is an error with a code frame, and a pubspec value that isn't a bool is serde's own error: `invalid pubspec.yaml: fespalier.deferred: invalid type: string "maybe", expected a boolean at line 3 column 13`. Like every `route.dart` constant it is inherited by `(group)` folders and folders without a page, and needs no page beside it. `fsp routes` tags such a route `deferred`, `--json` has `"deferred":true` (only there for a deferred route), `--graph` marks it, and `AppManifest`'s `RouteInfo.deferred` says so at runtime.

**Only `page.dart` is deferred**, the page of a route (a tab layout's own page included). The rest is needed before a page exists, and stays in the main bundle:

| Stays eager                                    | Why                                                                                                             |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `layout.dart`                                  | It wraps a `Navigator` (a `StatefulNavigationShell` for tabs): a placeholder would unmount them and their state |
| `loading.dart`, `error.dart`                   | They are what shows while the code loads, or when loading it fails                                              |
| `guard.dart`, `redirect.dart`                  | They run synchronously, before any build, and decide before a byte of code is fetched                           |
| `data.dart`, `action.dart`                     | The typed routes, `matchUrl`, `dataAt` and `preload` name their providers synchronously                         |
| `meta.dart`, `transition.dart`, `present.dart` | Used in a `const` list, or build the `Page` itself                                                              |

A `redirect.dart` route has no page, so it is never deferred.

**What shows while it loads.** Navigation completes at once, as ever. The route's `Page` is built, its transition plays, the layout and the tab bar around it are there, and the page's place shows the nearest [`loading.dart`](data.md#datadart-a-function-a-selector-or-a-provider) (a centred spinner without one) until the code arrives. If it can't be fetched (offline, a stale deploy), the nearest `error.dart` shows with what `loadLibrary()` threw (a `DeferredLoadException` on the web), and its `retry` loads the code again. dart2js already tries a chunk three times before it gives up. Turning `deferred` on therefore binds the nearest `loading.dart` and `error.dart` to the route, as `data.dart` does, with the same rule: an inherited view must fit every route it covers (an `error.dart` that asks for a segment fails the route that has none, and one that asks for a query parameter adds it to the typed route).

**Once the code is loaded, the page is built synchronously**, with no `Future` and no extra frame, so a second visit or a visit after a preload costs nothing. The page's state survives the load.

**Data and code load in parallel.** A deferred page with a `data.dart` starts its code at the first build, beside the data (`DataView(library: ...)`), and shows the page when both are there; `loading.dart` covers both waits, `keep_previous` is unchanged, and a data error still gets the data's `retry`.

**Guards run first.** A guard that redirects means the page's code is never requested. Preloading never runs a guard and never navigates; it may download the code of a guarded page (code, not data), and the guard still decides when the page is reached. An unparsable segment shows `not_found.dart`, and loads no code.

**Preloading the code.** It goes with the data:

- `XRoute(...).preload(ref)` (and so a [`RouteLink`](#links-routelink) with `preload`, and `AppRoutes.preload(ref, uri)`) also starts the page's code. A route that reads no data returns a closed handle; the code, once loaded, stays loaded, so closing a handle only drops the data. A typed route preloads its own page's code, not the pages `go` stacks under it.
- `AppRoutes.deferred` lists the `DeferredLibrary` of each deferred route, and `AppRoutes.loadDeferred()` loads them all, which is the "once the app is idle" strategy: call it after the first frame. There is no `const preload = true;`, and no limit on how many load at once (each loads once, and the browser dedups).
- `RouteLink` with a `uri:` and a `RouteLinkScope.match` preloads through the matched route's `preload`.

**Platforms.** On the web each deferred page is a `main.dart.js_N.part.js`. Elsewhere the code is in the binary already, but `loadLibrary()` still takes a turn of the event loop, so a page shows its `loading.dart` for about a frame on its first visit unless it was preloaded. Load them before `runApp` there: it costs no I/O, and keeps a deferred page's restorable state working on Android and iOS.

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) await AppRoutes.loadDeferred();
  runApp(const ProviderScope(child: MyApp()));
}
```

Android deferred components (a Play Store feature) are not tried: `loadDeferred` would download all of them. `--wasm` compiles, and whether it splits is not verified; correctness doesn't depend on it. `examples/shop` defers `/checkout` and `/products/:id`; [`fsp size`](cli.md#web-chunk-sizes-fsp-size) reports what each chunk costs per route.

**A type declared in a deferred `page.dart` is an error.** The generated file names the types of segments, query parameters and `extra` outside the page, and Dart can't use a deferred library's type there (`type_annotation_deferred_class`). An enum (`enum Sort { name, price }`) or an `extra` class declared in the page's own file is therefore reported, at the page, with what to do:

```text
error: `Sort` is declared in this page.dart, which is deferred, and the generated code names it outside the page (as the type of a segment, a query parameter or an `extra`): Dart can't use a deferred library's types there. Move `Sort` to a file of its own and import it here, or say `const deferred = false;` in this folder's route.dart
```

Move the type to a file of its own (`lib/models/sort.dart`) and import it in the page ([enum segments](routing.md#enum-segments) can be declared in any file the page imports), or leave that folder eager. A type declared in a page that is _not_ deferred is fine for a deferred child.

**Testing.** A deferred library's `loadLibrary()` completes only on the real event loop, which a widget test's `pump` never runs, so a test would show `loading.dart` for ever or end with "A Timer is still pending". `pumpRouter` therefore loads every deferred route's code first, in `runAsync`, and a deferred page is in the first settled frame like an eager one. A test that pumps a router of its own does the same itself, before `pumpWidget`:

```dart
await tester.runAsync(AppRoutes.loadDeferred);
```

Forgetting it is a `FlutterError` in a debug build, not a hang: _"The code of products/$id/page.dart is not loaded, and a widget test can't load it while it pumps."_ The loading state of a real deferred page can't be seen in a widget test; test your own `loading.dart`, or `DeferredLibrary(() => completer.future, 'x/page.dart', loadsInFakeAsync: true)` with a `DeferredView`.

**Not built:** deferring a `layout.dart`, a `const preload = true;` strategy, a cap on parallel loads, and a `deferred: auto` mode (dart2js already makes a chunk of each deferred import, and moves shared code into shared chunks: `deferred: true` in the pubspec and `const deferred = false;` on the landing page is "everything split"). Don't defer the landing page: it would show `loading.dart` before its first paint.
