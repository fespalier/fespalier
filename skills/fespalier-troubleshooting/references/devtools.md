# The DevTools extension (since 0.7.0)

Since 0.7.0 fespalier has a Flutter DevTools extension: a `fespalier` tab for a running app in
debug or profile mode. It shows the route tree `fsp` wrote, the router's location, its stack and the
history of the locations it committed, and takes a location to `go`, `push` or `replace` to. Use it to
see what a live app is doing before reading code: the README's
[DevTools extension](https://github.com/vaam-apps/fespalier#devtools-extension) section is the
user documentation.

The tab shows locations, the stack and the tree. Guards, data and actions are not followed in 0.7.0:
the tree lists their files as sites, and that is all.

## When to reach for it

| The question                                                | Where                                                                                        |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Which file serves this URL?                                 | **Location**: the route class and its file. **Routes** (or **Match**) for a URL not open now |
| Why is this page's parameter `null`?                        | **Location**, Parameters: name, declared type and the value the app's parser made of the URL |
| What is on the stack, and which layout is around a page?    | **Stack**: pages, `layout …` and `tabs … · tab n` shells, `pushed` pages                     |
| How did I get here: a `go`, a `push`, a redirect?           | **Location**, History: `initial`, `go`, `push`, `pop`, `replace`, `refresh` per commit       |
| Does `/orders/5/refund` match, and what are its parameters? | The go-to bar's **Match**: runs no guard, builds nothing, navigates nowhere                  |
| Which guard, `data.dart` or action does a route have?       | **Routes**, select a row: the sites on that route (they are listed, not followed)            |

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

## Traps

- **No tab in a release build, by design.** `kFespalierDevTools` is a `const` that is false there,
  and the service extensions, the route tree and the hooks are compiled out. A profile build has them.
- **No tab on fespalier before 0.7.0**, and an app that never calls `AppRoutes.mount()` or `router()` has
  nothing registered.
- **The tab is empty until the first `mount()`**, and shows no location until the router has committed one.
- **`--dart-define=fespalier.devtools=false` turns it off in debug too**, which is also how to rule it out
  when something is flaky.
- **`app.g.dart` now calls `devToolsRegister` and `devToolsAttach`** under `if (kFespalierDevTools)`, and
  holds the tree in `_devToolsTree`. Never remove them by hand; `fsp gen` writes them back.
- **A hot reload changes the tree and sends no event**: press the refresh button. A hot restart is a new
  app and reloads by itself.
- **The tab loads Flutter's CanvasKit from `gstatic.com`**, as a Flutter web app does by default: with no
  network, DevTools shows a blank tab.
- **Several routers: the last one attached is shown**, through a weak reference, so a disposed router does
  not leak.
- **A profile build on the web minifies class names.** The route class a location is matched to is its
  `runtimeType` name, so the tab falls back to the route's path template, which a localized path may not
  match.
- **A `data.dart` that returns or selects a provider** is listed in `fsp routes --graph json` with
  `"traced": false`: the extension lists the site and does not follow it.

## What the app answers (protocol 1)

For a tool of your own. All are `dart:developer` service extensions; every answer and event carries
`"protocol": 1`, and a change that only adds keys stays protocol 1: ignore keys you do not know, and ask
for what `hello`'s `features` lists.

| Method                   | Parameters                                          | Errors                                                                                     |
| ------------------------ | --------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `ext.fespalier.hello`    | none                                                |                                                                                            |
| `ext.fespalier.tree`     | none                                                |                                                                                            |
| `ext.fespalier.snapshot` | none                                                |                                                                                            |
| `ext.fespalier.match`    | `location`                                          | ``missing parameter `location` ``, `no fespalier router attached` (no app registered)      |
| `ext.fespalier.navigate` | `mode` (`go`, `push`, `replace`, `pop`), `location` | ``unknown mode `teleport`: one of go, push, replace, pop``, `no fespalier router attached` |
| `ext.fespalier.clear`    | `what` (`history`, `all`)                           | ``unknown `what` `x`: one of history, all``                                                |

A bad parameter is the JSON-RPC code `-32602`, any other failure `-32000`. Events are
`fespalier:registered` and `fespalier:navigation`, posted only while a tool listens, each with an
`"event"` number from one counter: a number that skips means events were missed, so fetch `snapshot`.
A user value (an `extra`, a parsed parameter) is sent as `{"type", "text"}`, the text cut to 200
characters, and `<toString threw>` when its `toString` throws.

If the extension itself fails, the app prints **`fespalier DevTools: … (not shown again)`** once and carries
on: nothing here changes what a navigation does, and in debug it starts no timer, schedules no frame and
reads no provider.
