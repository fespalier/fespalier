# The DevTools extension (since 0.7.0)

Since 0.7.0 fespalier has a Flutter DevTools extension: a `fespalier` tab for a running app in
debug or profile mode. It shows the route tree `fsp` wrote, the router's location, its stack and the
history of the locations it committed, which guards and redirects answered, the state of every
`data.dart` provider, and the runs of the actions; it takes a location to `go`, `push` or `replace`
to, builds a provider again, and asks the IDE to open a file. Use it to see what a live app is doing
before reading code: the README's
[DevTools extension](https://github.com/vaam-apps/fespalier#devtools-extension) section is the
user documentation.

## When to reach for it

| The question                                                | Where                                                                                        |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Which file serves this URL?                                 | **Location**: the route class and its file. **Routes** (or **Match**) for a URL not open now |
| Why is this page's parameter `null`?                        | **Location**, Parameters: name, declared type and the value the app's parser made of the URL |
| What is on the stack, and which layout is around a page?    | **Stack**: pages, `layout …` and `tabs … · tab n` shells, `pushed` pages                     |
| How did I get here: a `go`, a `push`, a redirect?           | **Location**, History: `initial`, `go`, `push`, `pop`, `replace`, `refresh` per commit       |
| Does `/orders/5/refund` match, and what are its parameters? | The go-to bar's **Match**: runs no guard, builds nothing, navigates nowhere                  |
| Which guard redirected me, or did not run?                  | **Guards**: `pass`, `redirect` (with where to), `pending`, `error`, `skipped` per decision   |
| What led to this redirect chain?                            | **Location**, History: the badge (`2 guards`) on the entry opens the decisions behind it     |
| Is this data loading, cached, failed or rebuilt?            | **Data**: `loading`, `data`, `error`, `stream`, `disposed`, builds, key, value               |
| Why does a page show stale data?                            | **Data**: when it was last updated; **Invalidate** builds it again                           |
| Did the action run, and what did it return or throw?        | **Actions**: `running`, `done`, `error`, how long, the input and the result                  |
| Which guard, `data.dart` or action does a route have?       | **Routes**, select a row: the sites on that route, each with an **Open in IDE** button       |

`fsp routes --graph json` prints the same tree without an app.

## Setup

- Run the app in **debug or profile** mode and open DevTools: the tab shows while the app is connected.
- DevTools asks once per project before loading a third-party extension. To skip the question, commit a
  `devtools_options.yaml` next to the `pubspec.yaml` whose `extensions:` list has `- fespalier: true`
  (`examples/features` has one).
- `AppRoutes.router()` attaches its router itself. An app that mounts the routes into a `GoRouter` of
  its own (`AppRoutes.mount()`) calls `devToolsAttach(router)` once, as `if (kFespalierDevTools) devToolsAttach(router);` (both names
  come from `package:fespalier/fespalier.dart`).
- DevTools finds the extension in every package of the app, git and path dependencies included.

## What the status line says

Quoted from the extension; each is the whole text of the line.

| Text                                                                                                               | Cause and fix                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| `Waiting for the app…`                                                                                             | DevTools is not connected to an app yet. Run the app, or attach DevTools to it                                                       |
| `This app does not use fespalier 0.7.0 or later, or runs in release mode`                                          | The app has no `ext.fespalier.hello`: an older fespalier, a release build, or `--dart-define=fespalier.devtools=false`               |
| `The app speaks protocol 2; this extension speaks 1`                                                               | The app's fespalier and the extension in DevTools are from different protocols. Use the extension that came with the app's fespalier |
| `fespalier is loaded, but the app has not mounted its routes yet`                                                  | `AppRoutes.mount()` (or `router()`) has not run yet                                                                                  |
| `fespalier is loaded but no router is attached: call devToolsAttach(router) if you mount() into your own GoRouter` | The routes were mounted into your own `GoRouter`, which nothing attached. Call `devToolsAttach(router)`                              |
| `Could not read the app: …`                                                                                        | A call failed; the text after the colon is what the app or the VM said. **Retry** or the refresh button                              |
| `fespalier · protocol 1 · lib/app · router attached`                                                               | All is well                                                                                                                          |

## What the Guards, Data and Actions tabs say

Quoted from the extension.

| Text                                                                               | Meaning                                                                                                                                                               |
| ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `No guard has answered yet.`                                                       | No guard or `redirect.dart` ran since the app started or since **Clear guards**. Navigate to a guarded route                                                          |
| `Every result is filtered out.`                                                    | Every result chip is off: turn one on                                                                                                                                 |
| `segments did not parse`                                                           | Result `skipped`: a segment of the URL did not parse as its declared type, so the guard that reads it did not run and the page shows not-found                        |
| `No data.dart provider was built yet.`                                             | No page has read a `data.dart` yet                                                                                                                                    |
| `Every provider shown here was disposed: turn on "Show disposed".`                 | Every provider is disposed (nothing watches it), and disposed ones are hidden by default                                                                              |
| `Not traced`                                                                       | The list of `data.dart` files that return or select a provider of their own: fespalier cannot see them, use Riverpod's DevTools tab                                   |
| `that provider is not alive any more, so there is nothing to invalidate`           | **Invalidate** on a provider that was disposed, or whose `Ref` is gone                                                                                                |
| `No action has run yet.`                                                           | No action ran since the app started or since **Clear actions**                                                                                                        |
| `guard #3 is no longer kept`                                                       | The history entry names a guard decision the app dropped (it keeps the last 200)                                                                                      |
| `This app does not report its guards: it uses a fespalier from before this panel.` | The app's `hello` does not list `guards` (`data` and `actions` say the same for theirs): a pinned development commit of 0.7.0 from before the panel. Update fespalier |

## Traps

- **No tab in a release build, by design.** `kFespalierDevTools` is a `const` that is false there,
  and the service extensions, the route tree and the hooks are compiled out. A profile build has them.
- **No tab on fespalier before 0.7.0**, and an app that never calls `AppRoutes.mount()` or `router()` has
  nothing registered.
- **The tab is empty until the first `mount()`**, and shows no location until the router has committed one.
- **`--dart-define=fespalier.devtools=false` turns it off in debug too**, which is also how to rule it out
  when something is flaky.
- **`app.g.dart` calls `devToolsRegister`, `devToolsAttach`, `traceGuard` and `traceData`**, passes `site:` to
  each action provider, and holds the tree in `_devToolsTree`. Never remove them by hand; `fsp gen` writes
  them back. `traceGuard` and `traceData` return their last argument, the very object, so a sync guard or
  a sync `data.dart` stays sync and a `Future` is the one go_router or Riverpod awaits; in release they
  are inlined away.
- **A hot reload changes the tree and sends no event**: press the refresh button. A hot restart is a new
  app and reloads by itself.
- **The tab loads Flutter's CanvasKit from `gstatic.com`**, as a Flutter web app does by default: with no
  network, DevTools shows a blank tab.
- **Several routers: the last one attached is shown**, through a weak reference, so a disposed router does
  not leak. Providers are told apart by a container number.
- **A profile build on the web minifies class names.** The route class a location is matched to is its
  `runtimeType` name, so the tab falls back to the route's path template, which a localized path may not
  match.
- **A `data.dart` that returns or selects a provider** is listed in `fsp routes --graph json` with
  `"traced": false`: the Data tab lists the file under **Not traced** and does not follow it.
- **Who holds a provider is not shown** (the page, a `PrefetchHandle`, a `RouteLink` preload): Riverpod does
  not export what that needs. Use Riverpod's own DevTools tab. fespalier adds no `ProviderObserver`.
- **A guard or a data function that throws before it returns** is not shown: the wrapper only sees what
  came back. go_router or Riverpod get the error as they always did.
- **A `Stream` provider shows the state `stream` and no value**, because nothing listens to the stream.
- **Guards and data are what the generated code reports.** A guard that runs again because a provider it
  watches changed (`refGuard` refreshes the router) is a new decision only when the router asks again.
- **Open in IDE is unverified.** It posts a `navigate` event on the `ToolEvent` stream with a `package:`
  URI (`package:shop/app/products/$id/page.dart`), the way Riverpod's extension does. Whether the IDE
  opens it from a `package:` URI depends on its DevTools integration; if nothing opens, the file is in
  the button's tooltip.

## What the app answers (protocol 1)

For a tool of your own. All are `dart:developer` service extensions; every answer and event carries
`"protocol": 1`, and a change that only adds keys stays protocol 1: ignore keys you do not know, and ask
for what `hello`'s `features` lists (`navigation`, `match`, `navigate`, `guards`, `data`, `actions`,
`open`).

| Method                     | Parameters                                          | Errors                                                                                                                                                                                              |
| -------------------------- | --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ext.fespalier.hello`      | none                                                |                                                                                                                                                                                                     |
| `ext.fespalier.tree`       | none                                                |                                                                                                                                                                                                     |
| `ext.fespalier.snapshot`   | none                                                |                                                                                                                                                                                                     |
| `ext.fespalier.match`      | `location`                                          | ``missing parameter `location` ``, `no fespalier router attached` (no app registered)                                                                                                               |
| `ext.fespalier.navigate`   | `mode` (`go`, `push`, `replace`, `pop`), `location` | ``unknown mode `teleport`: one of go, push, replace, pop``, `no fespalier router attached`                                                                                                          |
| `ext.fespalier.clear`      | `what` (`history`, `guards`, `actions`, `all`)      | ``unknown `what` `x`: one of history, guards, actions, all``                                                                                                                                        |
| `ext.fespalier.invalidate` | `id` (a data record's)                              | ``missing parameter `id` ``, ``parameter `id` is not a number: `x` ``; `{"ok": false}` for an id that is unknown, disposed or whose `Ref` is gone                                                   |
| `ext.fespalier.open`       | `file` (one of the tree's `file`s)                  | ``missing parameter `file` ``, `` `x.dart` is not a file of the route tree ``, `no fespalier app registered`, `the app folder is not a folder of a package under lib/` (`app_dir` is not in `lib/`) |

A bad parameter is the JSON-RPC code `-32602`, any other failure `-32000`. Events are
`fespalier:registered`, `fespalier:navigation`, `fespalier:guard`, `fespalier:data` and
`fespalier:action`, posted only while a tool listens, each with an `"event"` number from one counter:
a number that skips means events were missed, so fetch `snapshot`. A `guard` event is sent again with
the same `seq` when an async guard settles; a `data` event on every build, settle, failure and disposal
(one record per container, site and key, and the `id` is what `invalidate` takes); an `action` event at
the start and the end of a run. The lists are bounded: 100 locations, 200 guard decisions, 100 action
runs, the live providers and the last 50 disposed. A user value (an `extra`, a parsed parameter, a data
key or value, an action's input or result) is sent as `{"type", "text"}`, the text cut to 200
characters, `<toString threw>` when its `toString` throws, and `<gone>` when a value that is held
weakly was collected.

If the extension itself fails, the app prints **`fespalier DevTools: … (not shown again)`** once and carries
on: nothing here changes what a navigation, a guard, a provider or an action does, and in debug it starts
no timer, schedules no frame, reads no provider and listens to no provider or stream.
