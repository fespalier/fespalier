# DevTools extension

Since 0.7.0, fespalier has an extension for [Flutter DevTools](https://docs.flutter.dev/tools/devtools): a
`fespalier` tab that shows, in a running app, what the router is doing and which file each route comes
from. It answers:

## What it shows

- **Which file serves this URL?** The _Location_ tab names the route and its `page.dart`. The _Routes_
  tab is the whole tree with the route the router is at highlighted, and its **Match** button says
  which route any location is, without going there.
- **Why is this page's parameter null?** The parameters are shown with their declared type and the
  value the app's own parser made of the URL, and the query and the `extra` beside them. A location no
  route has shows go_router's error.
- **What is on the stack?** The _Stack_ tab lists the pages, the layouts and tab layouts around them, and
  the pages that were pushed, each with its route and file.
- **How did I get here?** The history under _Location_ lists every location the router committed,
  newest first, with whether it was a `go`, a `push`, a `pop`, a `replace` or a refresh.
- **Can I try a URL?** The go-to bar above the tabs takes a location and a `go`, `push` or `replace`,
  and has a **Pop** button. It asks the app's router, so guards and redirects run as they do for a
  link.
- **Which guard redirected me?** The _Guards_ tab lists every guard and `redirect.dart` that answered,
  newest first: the location it was asked about, its file and route, and its result: `pass`, `redirect`
  (with where to), `pending` (an async guard that has not answered), `error`, or `skipped` (a segment
  did not parse, so the guard did not run and the page shows not-found). Chips filter by result. A
  redirect chain (`/admin` to `/login`) is one entry in the history, and the badge on it opens the
  decisions behind it.
- **Is this data loading or cached?** The _Data_ tab lists the provider of every `data.dart` that was
  built: its file and route, the key (the segments and query it is keyed by), its state (`loading`,
  `data`, `error`, `stream` or `disposed`), how often it was built, when, and what it holds. **Invalidate**
  builds one again. Since 0.8.1 a provider fespalier built also shows how many listeners it has, and
  **Holders** lists who keeps it: the page's view, a section's view, a `prefetch` / `preload` handle (and
  for how long), a `RouteLink` preload, and how many other listeners there are (`ref.watch` or `listen`
  in your code, or another provider). A `data.dart` that returns or selects the app's own provider is
  shown too, marked `app provider`, with the state the page saw (since 0.8.1).
- **What did that action do?** The _Actions_ tab lists the runs of the `action.dart` functions, newest
  first: the function, its key and input, `running`, `done` or `error`, how long it took and what it
  returned or threw.
- **Open in IDE.** A route's details under _Routes_ (and each guard, data and action file listed there)
  have a button that asks the IDE to open the file.

## How to see it

**How to see it.** Run the app in debug or profile mode and open DevTools: the `fespalier` tab is there
when the app is connected. DevTools asks once per project before it loads an extension (the Extensions
button), or you commit a `devtools_options.yaml` next to the `pubspec.yaml`:

```yaml
description: This file stores settings for Dart & Flutter DevTools.
documentation: https://docs.flutter.dev/tools/devtools/extensions#configure-extension-enablement-states
extensions:
  - fespalier: true
```

DevTools finds the extension in every package the app depends on, a git or a path dependency included.
`AppRoutes.router()` hands its router to the extension itself. An app that
[mounts](migration.md#adopting-fespalier-in-a-go_router-app) the routes into a `GoRouter` of its own attaches it once:

```dart
final router = GoRouter(routes: [...yourRoutes, ...AppRoutes.mount()]);
if (kFespalierDevTools) devToolsAttach(router);
```

## What it costs

**What it costs.** Nothing in a release build: `kFespalierDevTools` is a `const` that is false there, the
generated `app.g.dart` calls the extension's code only under `if (kFespalierDevTools)`, and
the compiler removes the service extensions, the route tree and the code that serves them. The calls
that follow the guards, the data and the views are wrappers that return what they are given
(`traceGuard(state, 'g5@6', guard(...))`, `traceData(ref, 'd37', id, data(...))`,
`watchData(ref, 'd37', provider)`); in a release build they are the identity (`watchData` is exactly
`ref.watch`) and the compiler inlines them away. CI builds an app with a guard, a `data.dart` and an
action for profile and for release and checks that the release build has none of it. What stays in a
release build is one short string per action (its site, an argument of the generated action provider).

In a debug or profile build it adds one listener to the router's delegate, an `onDispose`, an
`onAddListener` and an `onRemoveListener` callback per build of a `data.dart` provider (the last two count
its listeners; since 0.8.1), and lists of what happened that stop at 100 locations, 200 guard
decisions, 100 action runs, and the providers that are alive plus the last 50 disposed. The views, the
prefetch handles and the `RouteLink` preloads it lists as holders are held weakly. There is no
timer, no frame, no read of a provider, no listener on a provider, and nothing that answers unless
DevTools asks. (`ProviderContainer.exists`, which reads nothing, is asked of a container for an app's own
provider only when DevTools asks for a snapshot or for holders, and before the 101st live one is recorded.
`_devToolsProviders` in `app.g.dart` is a function that is called once, when DevTools first needs it.) **A guard or a data function that answers at once still does:** the wrapper returns the very
object it was given, so a synchronous guard stays synchronous, a `Future` is the `Future` go_router or
Riverpod awaits, and the only thing added to one is a side `then` that records how it ended and handles
its own errors. A `Stream` is not listened to. A bug in any of it is printed once and dropped; it never
changes what a navigation, a guard, a provider or an action does.
`--dart-define=fespalier.devtools=false` takes it out of a debug build too.

## Limits

- The tab loads Flutter's CanvasKit from `gstatic.com`, as a Flutter web app does by default, so it
  needs a network connection.
- It follows one router, the last one attached. Locations and the stack are the router's own, so a
  page that a `Navigator` of the app (not go_router) opened is not in them.
- A hot reload changes the route tree and says nothing about it: press the refresh button. A hot restart
  is a new app and reloads by itself.
- The route class a location is matched to is the class's `runtimeType` name. A profile build on the web
  minifies class names, so the tab finds the route by its path template instead, which a
  [localized path](routing.md#localized-paths) may not match.
- An app provider (a `data.dart` that returns or selects one) is seen through fespalier's views: its
  state is what the last page or section that watched it got, it has no build count, and its other
  listeners are not visible. A `.select(...)` can't be invalidated or checked for being alive. Until a
  page, a section or a preload watches it, its file is listed under _Not watched yet_ (since 0.8.1). The
  same goes for a guard or a data function that throws before it returns anything: go_router or Riverpod
  get the error as they always did, and the tab shows nothing for it.
- **Holders** are the ones fespalier creates (views, prefetches, `RouteLink` preloads); anything else is
  counted, for a provider fespalier built, as other listeners, and not named. Riverpod 3.4 does not
  export who listens to a provider (`ProviderElement` and its dependents are internal); its own DevTools
  tab reads them through internals. fespalier does not add a `ProviderObserver` either: it does not own
  your `ProviderScope`. A prefetch made before any page watched a selector's provider with parameters is
  attached when a page first does.
- A provider that returns a `Stream` shows the state `stream` and no value: nothing listens to it on the
  tab's behalf.
- **Open in IDE** posts a `navigate` event on the `ToolEvent` stream with a `package:` URI of the file, the
  way Riverpod's DevTools extension opens a file. Whether VS Code and IntelliJ open a `package:` URI
  from it is **unverified**; it needs the IDE's DevTools integration to be listening.

## Protocol for tool authors

**For tool authors.** The extension and the app talk through `dart:developer`'s service extensions and
events, protocol 1. Every response and event has `"protocol": 1` and an `"event"` number on events (one counter
for all kinds: a number that skips means events were missed, and `snapshot` has the state). A change that only adds is not a
new protocol: a reader ignores keys it does not know, and `hello` lists what the app can answer in
`features`. A user value, like an `extra`, is never sent as it is but as `{"type", "text"}`, its runtime
type and its text cut to 200 characters. The records are in
[`packages/fespalier/lib/src/devtools/protocol.dart`](../packages/fespalier/lib/src/devtools/protocol.dart),
which imports nothing.

| Service extension          | Parameters                                                               | Answers                                                                                   |
| -------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- |
| `ext.fespalier.hello`      | none                                                                     | the protocol, whether the app registered and attached a router, and its `features`        |
| `ext.fespalier.tree`       | none                                                                     | the route tree, as `fsp routes --graph json` prints it                                    |
| `ext.fespalier.snapshot`   | none                                                                     | the location, the stack, the history and the number of the last event                     |
| `ext.fespalier.match`      | `location`                                                               | the route a location is and its parsed parameters; it runs no guard and builds nothing    |
| `ext.fespalier.navigate`   | `mode` (`go`, `push`, `replace` or `pop`) and `location` (not for `pop`) | `{"ok": true}` once the router has been asked                                             |
| `ext.fespalier.clear`      | `what` (`history`, `guards`, `actions` or `all`)                         | `{"ok": true}`; what was named is emptied and the event counter goes on                   |
| `ext.fespalier.invalidate` | `id` (a data record's)                                                   | `{"ok": true}` when that provider was alive and was invalidated, `{"ok": false}` when not |
| `ext.fespalier.open`       | `file` (one of the tree's, relative to the app folder)                   | `{"ok": true}` once the IDE was asked, with a `package:` URI                              |
| `ext.fespalier.holders`    | `id` (a data record's)                                                   | who holds that provider now (since 0.8.1): `{found, alive, listeners, others, holders}`   |

| Event                  | Posted when                                                                          | Carries                                     |
| ---------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------- |
| `fespalier:registered` | the app registers, or a router is attached                                           | the number of the event                     |
| `fespalier:navigation` | the router commits a location                                                        | the number and the `record` of the entry    |
| `fespalier:guard`      | a guard or `redirect.dart` answers, and again (same `seq`) when an async one settles | the number and the `record` of the decision |
| `fespalier:data`       | a `data.dart` provider is built, settles, fails, is built again or is disposed       | the number and the `record` of the provider |
| `fespalier:action`     | an action starts and when it ends                                                    | the number and the `record` of the run      |

`hello`'s `features` lists what the app can answer: `navigation`, `match`, `navigate`, `guards`, `data`,
`actions`, `open`, `holders` and `watched` (the last two since 0.8.1). The `snapshot` has a `guards`, a `data` and an `actions` list, and a navigation record
names the `guards` behind it; a reader that finds one of the features missing finds those empty. A guard record is
`{seq, at, site, uri, fullPath, result, location, async, ms, error}`, a data record
`{id, site, key, container, state, builds, created, updated, value, error, via, provider, listeners}` and an action record
`{seq, site, key, input, state, started, ms, result, error}`; a `site` is a key of the tree's `sites`.
Since 0.8.1 a data record's `via` is `build` (fespalier built the provider) or `watch` (the app's own provider,
seen through a view; its `provider` is the provider's text and its `listeners` is null), and `holders` answers
`{found, alive, listeners, others, holders: [{kind, since, keepFor}]}`: `kind` is `view`, `section`, `prefetch`
or `link`, `keepFor` is milliseconds (null for until closed), `alive` is null when it can't be known, and
`others` is `listeners` minus the holders. `found` is false for an id that is not tracked.

An error is a JSON-RPC error with the code `-32602` for a missing or bad parameter and `-32000` otherwise,
and its detail says what was wrong. Events are posted only while a tool listens.
