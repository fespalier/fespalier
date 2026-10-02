# Documented claims that were not true

**Where the README and the code disagree, the code is right.** These skills live in the
fespalier repository, so a disagreement found here is fixed in the README in the same
change, and this page keeps the record: a reader whose app pins an older fespalier is
still reading that version's README.

## Wrong in the 0.3.0 README, fixed in 0.4.0

Each item was checked against v0.3.0 (`8b63d468`, 2026-10-01) by running `fsp` or a
widget test, and corrected in 0.4.0 (PR #18). On 0.3.0, trust the right-hand side.

1. **A family provider you write, keyed by a query parameter.** The 0.3.0 README said its
   record argument could name query parameters (`({int id, int? page})`). It can't: a
   provider you write is keyed by **segments only**, and a record field that is a query
   parameter is an error. 0.3.0's message for it was misleading (_for a query parameter
   make it optional and nullable_, when the field already was); 0.4.0 says _a provider
   you write can be keyed by segments only_ and names the function form. Key by a query
   parameter with `Future<T> data(Ref ref, {int? page})` or a selector.
2. **"A section's `data.dart` takes segments only"** (file kinds table). A section's
   `data()` takes query parameters too since 0.3.0.
3. **"`fsp watch` watches the app folder, so after adding an enum elsewhere run
   `fsp gen`."** It watches the rest of `lib/` too since 0.3.0, so editing an enum's file
   regenerates.
4. **"When a path has a segment that doesn't parse, guards are skipped."** Only a guard
   that **asks for segments or query parameters** is skipped. A guard that takes neither
   (only `uri`, `extra`, or nothing) still runs before the page's parse, so it can
   redirect `/items/abc` to a login page.
5. **`pumpRouter(tester, router, {overrides, container, settle})`.** It also has
   `retry:`, which **defaults to no retries**, unlike a real app. Pass
   `retry: ProviderContainer.defaultRetry` to test the app's policy.
6. **`fsp routes` tags.** They include `redirect` (and, since 0.4.0, `sibling`, and since
   0.5.0, `action`).
7. **"Each view file exports one public widget class."** Other public classes may sit
   in the file when **exactly one extends a `*Widget`** class; `fsp` errors only when it
   can't choose (_expected one public widget class, found BPage, Other_). Make helpers
   private rather than rely on it.
8. **`fsp check` in CI.** It writes and compares **nothing**, so it passes when the
   committed `lib/app.g.dart` is stale. To fail CI then, run `fsp gen` (or
   `dart run fespalier gen`) and `git diff --exit-code lib/app.g.dart`.
9. **`currentLocation(tester)` after a `push`.** In 0.3.0 it read
   `routeInformationProvider.value`, which go_router 18 does not update on a `push`, so it
   still reported the previous location. 0.4.0 changed the code to follow `push`; on
   0.3.0 read `router.routerDelegate.currentConfiguration.last.matchedLocation`.

Two error messages were wrong in the same way, and were fixed in 0.4.0:

- **Folder names.** 0.3.0 said a group or a static segment uses `a-z, 0-9, - _ . ~`; the
  code accepts **uppercase ASCII letters** too (`Products/` is a valid segment), and 0.4.0
  says `a-z, A-Z, 0-9, - _ . ~`. A space, other punctuation and non-ASCII are refused.
- **An optional parameter of a type that isn't a query type** (`{Widget? w}`): 0.3.0 told
  you to make it _optional and nullable_, which it already was. 0.4.0 says the type
  isn't a query type and lists the ones that are.

## Wrong in the 0.5.0 README, fixed in 0.6.0

On 0.5.0 trust the right-hand side. Checked against v0.5.0 (`c107ccf`) with a widget test
that records what the router tells the platform (`SystemChannels.navigation`).

1. **"`replace` doesn't put its location in the address bar on the web, so use `go` for state
   in the URL."** On 0.5.0 `replace` was go_router's: over a page with no page below it the
   new URL was reported to the browser, as a **new** history entry; over a page with one
   below it (a nested route, a `push`ed page) the address bar showed the URL of the page
   below instead (`/p` after replacing `/p/c/1` with `/p/c/2`). 0.6.0 makes
   `TypedLocation.replace` a `go` inside `Router.neglect` when the top page is not pushed, so
   the URL follows and the history entry is **replaced**; over a pushed page it is still
   go_router's `replace` (the stack stays) and follows `push_updates_url`. Using `go` for URL
   state keeps working on every version.
2. **`push` and the address bar.** A `push` never showed in the address bar (go_router's
   `optionURLReflectsImperativeAPIs` is off by default); 0.6.0 adds the `push_updates_url`
   pubspec key, and `router()` now assigns that go_router flag on every call.

## Things the README leaves out

As of v0.4.0:

- **`fsp` honours `FSP_DART`** (a path to `dart`) for `--format`; the README documents only
  `dart` on `PATH`.
- **`executables: fsp: fespalier`** in the package's `pubspec.yaml` means
  `dart pub global activate` can install it as `fsp`; the README documents only the
  binary installers, `cargo install` and `dart run fespalier`. (Not exercised here.)
