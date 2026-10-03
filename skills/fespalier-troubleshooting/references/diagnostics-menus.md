# Diagnostics: `nav.dart`, menus and breadcrumbs

Since 0.8.1 (`cli/src/resolve.rs`, `cli/src/menu.rs`). Each message below was produced by
`fsp check` on a tree that triggers it. `fespalier-layouts` has the rules behind them
(`references/menus-and-breadcrumbs.md`).

## The `nav.dart` file

| Message                                                                                                                                           | Cause and fix                                                                                                                    |
| ------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `` expected `const nav = Nav(label: '...');` ``                                                                                                   | The file has no variable called `nav`. A helper that happens to be called `nav.dart`: rename it into `_components/`              |
| `` `nav` is declared twice ``                                                                                                                     | Two `nav` variables; the second is flagged                                                                                       |
| `` `nav` must be `const` (AppMenu lists it in a const tree): write `const nav = Nav(...);` ``                                                     | `final nav = ...`: the generated tree is `const`                                                                                 |
| `` `nav` must be a `Nav(...)` call, so fsp can read its `order`: `const nav = Nav(label: 'Products', order: 1);` ``                               | `nav` is another class, a variable or a prefixed `x.Nav(...)`: write the call out                                                |
| `` `order` must be a whole-number literal, like `order: 2`: fsp sorts the menu with it ``                                                         | `order: 1.5`, a constant or an expression: use an integer literal                                                                |
| `` label() must return a String: `String label(BuildContext context) => ...` ``                                                                   | `label()` returns something else (or nothing is declared)                                                                        |
| ``label() must take `BuildContext context` first: the menu calls it while it builds``                                                             | The first parameter is missing, named or not a `BuildContext`                                                                    |
| ``label() can ask for the segments of its folder and above ($id); `nope` is none of them``                                                        | A parameter that is not a segment (`$id`, ... lists them). Query parameters, `uri` and `extra` are not available                 |
| `` label() gets no segments here (this folder and the ones above it have none); remove `id` ``                                                    | The folder has no `$segment` above it                                                                                            |
| `` `id` must be `required`: a menu entry always has its segments ``                                                                               | `{int id = 1}` or `{int? id}`: make it `required`                                                                                |
| `` label() takes segments as named parameters, e.g. `{required int id}` ``                                                                        | A positional parameter after `context`                                                                                           |
| ``give `id` a type (String, int, double or bool)``                                                                                                | An untyped segment parameter                                                                                                     |
| `` `$id` is String in a/data.dart:2 but int here ``                                                                                               | A `label()` types a segment differently from `data.dart`, `guard.dart` or the page: change it in **every** file that asks for it |
| warning `nav.dart in a folder with no page.dart or redirect.dart is a heading for the nav.dart files below it, and there are none; it is ignored` | A heading with no `nav.dart` below it (a folder with only a `nav.dart` gets this alone). Add a page, or delete the file          |

## At run time (no `fsp` message)

| Symptom                                                                                     | Cause and fix                                                                                                                        |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| ``no nav.dart is in or below the folder `x` `` (an assertion, debug builds)                 | `AppMenu.watch(ref, under: 'x')` names a folder with no `nav.dart` at or below it: use the folder's path under `lib/app/`            |
| go_router's own error that there is no `GoRouterState` above the widget, when a menu builds | `AppMenu.watch` or `breadcrumbs` called above the router (`MaterialApp.builder`). Call it in a layout or a page                      |
| An entry never shows                                                                        | Its folder has `$segments` and the location lacks them; `inMenu: false`; or a guard refuses it (`NavRefused.hide` is the default)    |
| An entry in a tab bar has no `tab`                                                          | `under:` names a folder other than the tab layout's own, or the entry is not a branch of it                                          |
| A menu does not follow a guard written with `ProviderContainer c`                           | That older form is read once per menu build; write it with `Ref ref` and `ref.watch` (0.5.0)                                         |
| `A Timer is still pending` in a test of a menu                                              | A guard awaits a `Future.delayed`: `await tester.pumpAndSettle()` before the test ends                                               |
| The test fails with the guard's exception though the menu looks right                       | A guard that throws is reported (`FlutterError.reportError`) and its entry stays pending: `expect(tester.takeException(), isA<X>())` |
| A guard runs "too often" (a request is repeated)                                            | A menu asks every guarded entry; guards must be cheap and pure. Use `NavRefused.show` to skip asking, or cache in a provider         |
