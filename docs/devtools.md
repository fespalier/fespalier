# DevTools extension

Since 0.7.0, fespalier has an extension for [Flutter DevTools](https://docs.flutter.dev/tools/devtools): a `fespalier` tab that shows, in a running app, what the router is doing and which file each route comes from.

## What it shows

- **Which file serves this URL?** The _Location_ tab names the route and its `page.dart`. The _Routes_ tab is the whole tree with the current route highlighted; its **Match** button says which route any location is, without going there.
- **Why is this page's parameter null?** Parameters are shown with their declared type and the value the app's own parser made of the URL, with the query and the `extra` beside them. A location no route has shows go_router's error. A pushed page whose guard has not passed (go_router showed it again after a refresh, and the guard runs again after the frame, since 0.21.0) shows `held: its guard runs again` there, and on the history entry of that navigation.
- **What is on the stack?** The _Stack_ tab lists the pages, the layouts and tab layouts around them, and the pages that were pushed, each with its route and file.
- **How did I get here?** The history under _Location_ lists every location the router committed, newest first, and whether it was a `go`, a `push`, a `pop`, a `replace` or a refresh.
- **Can I try a URL?** The go-to bar above the tabs takes a location and a `go`, `push` or `replace`, and has a **Pop** button. It asks the app's router, so guards and redirects run as they do for a link.
- **Which guard redirected me?** The _Guards_ tab lists every guard and `redirect.dart` that answered, newest first: the location it was asked about, its file and route, and its result:
  - `pass`, or `redirect` (with where to);
  - `pending`: an async guard that has not answered;
  - `error`;
  - `skipped`: a segment did not parse, so the guard did not run and the page shows not-found.

  Chips filter by result. A redirect chain (`/admin` to `/login`) is one entry in the history, and the badge on it opens the decisions behind it.

- **Is this data loading or cached?** The _Data_ tab lists the provider of every `data.dart` that was built: its file and route, the key (the segments and query it is keyed by), its state (`loading`, `data`, `error`, `stream` or `disposed`), how often it was built, when, and what it holds. **Invalidate** builds one again.
  - Since 0.8.1 a provider fespalier built also shows how many listeners it has, and **Holders** lists who keeps it: the page's view, a section's view, a `prefetch` / `preload` handle (and for how long), a `RouteLink` preload, and how many other listeners there are (`ref.watch` or `listen` in your code, or another provider).
  - A `data.dart` that returns or selects the app's own provider is shown too, marked `app provider`, with the state the page saw (since 0.8.1).
- **What did that action do?** The _Actions_ tab lists the runs of the `action.dart` functions, newest first: the function, its key and input, `running`, `done` or `error`, how long it took and what it returned or threw.
- **What do my adapters say?** Since 0.16.0 the _Adapters_ tab has a card for each package that called `DevToolsAdapters.show` (see [Adapters](adapters.md)): its title or package name, when it last showed, and its values, each with its type. A package may let you set a value from here (the local override of a flag, a notification to simulate): that key has a text field and a **Set** button, which asks the app to call the package's `onEdit` with the key and the text, and says why when the app refuses. The tab is empty until a package shows something: `No adapter has shown anything yet. An adapter can list its state here with DevToolsAdapters.show (since 0.16.0); none of the packages in this repository does yet.`
- **Open in IDE.** A route's details under _Routes_ (and each guard, data and action file listed there) have a button that asks the IDE to open the file.

## How to see it

Run the app in debug or profile mode and open DevTools: the `fespalier` tab is there when the app is connected. DevTools finds the extension in every package the app depends on (git and path dependencies too) and asks once per project before it loads one (the Extensions button), or you commit a `devtools_options.yaml` next to the `pubspec.yaml`:

```yaml
description: This file stores settings for Dart & Flutter DevTools.
documentation: https://docs.flutter.dev/tools/devtools/extensions#configure-extension-enablement-states
extensions:
  - fespalier: true
```

`AppRoutes.router()` hands its router to the extension itself. An app that
[mounts](migration.md#adopting-fespalier-in-a-go_router-app) the routes into a `GoRouter` of its own attaches it once:

```dart
final router = GoRouter(routes: [...yourRoutes, ...AppRoutes.mount()]);
if (kFespalierDevTools) devToolsAttach(router);
```

## What DevTools costs

**Nothing in a release build.** `kFespalierDevTools` is a `const` that is false there, and the generated `app.g.dart` calls the extension's code only under `if (kFespalierDevTools)`, so the compiler removes the service extensions, the route tree and the code that serves them.

The calls that follow the guards, the data and the views are wrappers that return what they are given:

```dart
traceGuard(state, 'g5@6', guard(...))
traceData(ref, 'dProductsId', id, data(...))
watchData(ref, 'dProductsId', provider)
```

In a release build they are the identity (`watchData` is exactly `ref.watch`) and the compiler inlines them away. What stays is one short string per action (its site, an argument of the generated action provider).

**In a debug or profile build** it adds:

- one listener to the router's delegate;
- an `onDispose`, an `onAddListener` and an `onRemoveListener` callback per build of a `data.dart` provider (the last two count its listeners; since 0.8.1);
- lists of what happened, which stop at 100 locations, 200 guard decisions, 100 action runs, and the providers that are alive plus the last 50 disposed. The views, the prefetch handles and the `RouteLink` preloads it lists as holders are held weakly.

Since 0.16.0 an adapter package that calls `DevToolsAdapters.show` adds one entry (at most 32 adapters with 64 values each, the values already turned to text) and posts an event; the call is empty in a release build. It starts no timer and listens to nothing.

There is no timer, no frame, no read of a provider, no listener on a provider, and nothing that answers unless DevTools asks.

**A guard or a data function that answers at once still does:** the wrapper returns the very object it was given, so a synchronous guard stays synchronous and a `Future` is the `Future` go_router or Riverpod awaits. The only thing added to a `Future` is a side `then` that records how it ended and handles its own errors. A `Stream` is not listened to. A bug in any of it is printed once and dropped; it never changes what a navigation, a guard, a provider or an action does. `--dart-define=fespalier.devtools=false` takes it out of a debug build too.

## Limits

- The tab loads Flutter's CanvasKit from `gstatic.com`, as a Flutter web app does by default, so it needs a network connection.
- It follows one router, the last one attached. Locations and the stack are the router's own, so a page that a `Navigator` of the app (not go_router) opened is not in them.
- A hot reload changes the route tree and says nothing about it: press the refresh button. A hot restart is a new app and reloads by itself.
- The route class a location is matched to is the class's `runtimeType` name. A profile build on the web minifies class names, so the tab finds the route by its path template instead, which a [localized path](routing.md#localized-paths) may not match.
- An app provider (a `data.dart` that returns or selects one) is seen through fespalier's views: its state is what the last page or section that watched it got, it has no build count, and its other listeners are not visible. A `.select(...)` can't be invalidated or checked for being alive. Until a page, a section or a preload watches it, its file is listed under _Not watched yet_ (since 0.8.1).
- A guard or a data function that throws before it returns anything shows nothing in the tab: go_router gets a guard's error as a `GuardFailure` and the error view shows (since 0.21.0), and Riverpod gets a data function's error as it always did.
- **Holders** are the ones fespalier creates (views, prefetches, `RouteLink` preloads). Anything else is counted, for a provider fespalier built, as other listeners, and not named: Riverpod does not export who listens to a provider, and fespalier does not add a `ProviderObserver` (it does not own your `ProviderScope`). A prefetch made before any page watched a selector's provider with parameters is attached when a page first does.
- A provider that returns a `Stream` shows the state `stream` and no value: nothing listens to it on the tab's behalf.
- **Open in IDE** posts a `navigate` event on the `ToolEvent` stream with a `package:` URI of the file, the way Riverpod's DevTools extension opens a file. Whether VS Code and IntelliJ open a `package:` URI from it is **unverified**; it needs the IDE's DevTools integration to be listening.

## Protocol for tool authors

The extension and the app talk through `dart:developer`'s service extensions and events, protocol 1.

- Every response and event has `"protocol": 1`, and events an `"event"` number (one counter for all kinds: a number that skips means events were missed, and `snapshot` has the state).
- A change that only adds is not a new protocol: a reader ignores keys it does not know, and `hello` lists what the app can answer in `features`.
- A user value, like an `extra`, is never sent as it is but as `{"type", "text"}`: its runtime type and its text cut to 200 characters.

The records are in [`packages/fespalier/lib/src/devtools/protocol.dart`](../packages/fespalier/lib/src/devtools/protocol.dart), which imports nothing.

| Service extension           | Parameters                                                               | Answers                                                                                                |
| --------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `ext.fespalier.hello`       | none                                                                     | the protocol, whether the app registered and attached a router, and its `features`                     |
| `ext.fespalier.tree`        | none                                                                     | the route tree, as `fsp routes --graph json` prints it                                                 |
| `ext.fespalier.snapshot`    | none                                                                     | the location, the stack, the history and the number of the last event                                  |
| `ext.fespalier.match`       | `location`                                                               | the route a location is and its parsed parameters; it runs no guard and builds nothing                 |
| `ext.fespalier.navigate`    | `mode` (`go`, `push`, `replace` or `pop`) and `location` (not for `pop`) | `{"ok": true}` once the router has been asked                                                          |
| `ext.fespalier.clear`       | `what` (`history`, `guards`, `actions` or `all`)                         | `{"ok": true}`; what was named is emptied and the event counter goes on                                |
| `ext.fespalier.invalidate`  | `id` (a data record's)                                                   | `{"ok": true}` when that provider was alive and was invalidated, `{"ok": false}` when not              |
| `ext.fespalier.open`        | `file` (one of the tree's, relative to the app folder)                   | `{"ok": true}` once the IDE was asked, with a `package:` URI                                           |
| `ext.fespalier.holders`     | `id` (a data record's)                                                   | who holds that provider now (since 0.8.1): `{found, alive, listeners, others, holders}`                |
| `ext.fespalier.adapterEdit` | `adapter`, `key` and `value` (the text typed; it may be empty)           | `{"ok": true}` once the adapter's `onEdit` ran, `{"ok": false, "reason": ...}` when not (since 0.16.0) |

| Event                  | Posted when                                                                          | Carries                                     |
| ---------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------- |
| `fespalier:registered` | the app registers, or a router is attached                                           | the number of the event                     |
| `fespalier:navigation` | the router commits a location                                                        | the number and the `record` of the entry    |
| `fespalier:guard`      | a guard or `redirect.dart` answers, and again (same `seq`) when an async one settles | the number and the `record` of the decision |
| `fespalier:data`       | a `data.dart` provider is built, settles, fails, is built again or is disposed       | the number and the `record` of the provider |
| `fespalier:action`     | an action starts and when it ends                                                    | the number and the `record` of the run      |
| `fespalier:adapter`    | an adapter shows or hides its values (since 0.16.0)                                  | the number and the `record` of the adapter  |

`hello`'s `features` lists what the app can answer: `navigation`, `match`, `navigate`, `guards`, `data`, `actions`, `open`, `holders` and `watched` (the last two since 0.8.1) and `adapters` (since 0.16.0). A reader that finds one of the features missing finds those lists empty.

The `snapshot` has a `guards`, a `data` and an `actions` list (and, since 0.16.0, an `adapters` list, which an older app does not send: read it as empty), and a navigation record names the `guards` behind it. The records:

- guard: `{seq, at, site, uri, fullPath, result, location, async, ms, error}`
- data: `{id, site, key, container, state, builds, created, updated, value, error, via, provider, listeners}`
- action: `{seq, site, key, input, state, started, ms, result, error}`
- adapter (since 0.16.0): `{seq, adapter, title, at, values: [{key, value, editable}], truncated, removed}`

A `site` is a key of the tree's `sites`. Its spelling is not part of the protocol (since 0.20.0 a `data.dart`'s is `dProductsId` and an action's `aNotesId_edit`, where they were numbered by folder before).

Since 0.8.1 a data record's `via` is `build` (fespalier built the provider) or `watch` (the app's own provider, seen through a view; its `provider` is the provider's text and its `listeners` is null). `holders` answers `{found, alive, listeners, others, holders: [{kind, since, keepFor}]}`:

- `kind` is `view`, `section`, `prefetch` or `link`;
- `keepFor` is milliseconds (null for until closed);
- `alive` is null when it can't be known;
- `others` is `listeners` minus the holders;
- `found` is false for an id that is not tracked.

Since 0.16.0 an `adapter` record is what one package shows: `adapter` is its package name, each `value` is a `{type, text}` like any user value, `editable` says whether `adapterEdit` takes that key, `truncated` that the package gave more than the 64 values the app keeps, and `removed` that it hid its values (the reader drops it; `values` is then empty). One record is kept for each adapter, at most 32 (the one shown least recently goes, with a `removed` event), and the snapshot lists them by package name. `adapterEdit` answers `{"protocol": 1, "ok": false, "reason": "no adapter fespalier_flags is shown"}` for an adapter that shows nothing, ``"reason": "`limit` of fespalier_flags is not editable"`` for a key that is not editable, and `"reason": "onEdit threw: ..."` when the callback threw; a missing `adapter` or `key` is the usual error.

An error is a JSON-RPC error with the code `-32602` for a missing or bad parameter and `-32000` otherwise, and its detail says what was wrong. Events are posted only while a tool listens.
