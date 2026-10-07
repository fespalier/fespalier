# Route smoke tests and Maestro flows

Two ways to prove that every route opens: [`fsp test`](#route-smoke-tests-fsp-test) writes a widget test per route and runs in `flutter test`; [`fsp maestro`](#maestro-flows-fsp-maestro) writes flows that drive the real app. Both share the `samples:` they open the routes with. The other `fsp` commands are in the [CLI reference](cli.md).

## Maestro flows (`fsp maestro`)

Since 0.7.0. [Maestro](https://docs.maestro.dev) drives an app from the outside, through the platform's accessibility tree, so it cannot see a Flutter `Key`. It finds text, a `Semantics` label and a `Semantics(identifier:)`, which its `id:` selector matches. `fsp` gives every page one, and writes a smoke flow for each route that opens the route's URL and waits for that page.

**`semantics_ids: true`** in the `fespalier:` section of `pubspec.yaml` wraps each page's own widget in

```dart
Semantics(identifier: 'route:/products/:id', container: true, explicitChildNodes: true, child: ProductPage(id: v.id))
```

The identifier is `route:` and the pattern `fsp routes` prints (`route:/`, `route:/products/:id`, `route:/docs/*rest`, `route:/files/*path?`). It depends only on the folder path, so it is the same for every [localized spelling](routing.md#localized-paths) and every mount prefix, and it does not change when you rename a class. It is in the widget tree **if and only if the route's own page is built**:

- The wrapper sits on the innermost call, inside `DataView`, `DeferredView` and `SectionView`, so `loading.dart`, `error.dart` and `not_found.dart` do not carry it. A flow cannot pass while a spinner or an error shows, nor while a [deferred](navigation.md#deferred-routes-a-pages-code-on-demand) page's code is loading.
- go_router builds the whole matched stack, but the pages underneath the top one are off screen and out of the semantics tree: `/products/1` has `route:/products/:id` and not `route:/products`.
- Only a `page.dart` gets one: not a layout, a shell, a redirect or a not-found view.
- `Semantics` has no `const` constructor, so the wrapper is never `const`; a page that was `const` keeps its own `const` inside it, and the generated code passes the `const` lints.
- The identifier's node is empty: `container: true` gives it a node of its own, and `explicitChildNodes: true` (since 0.9.1) keeps every descendant out of it, so a screen reader reads each of the page's `Text` widgets as its own node. A page that wants one announcement groups its own text with `MergeSemantics`.
- With the key off (the default), nothing is generated for it.

**On the web, this is not free.** Flutter builds no semantics tree until a screen reader asks for one, so a driver that reads the page from outside finds nothing. With `semantics_ids: true` the generated `AppRoutes.mount()` (which `router()` calls, so an app that embeds the routes is covered too) first calls `ensureWebSemantics()` from `package:fespalier`. On the web it calls `SemanticsBinding.instance.ensureSemantics()` once and keeps the handle for the life of the app; anywhere else, and in every widget test, it does nothing. **The tree then stays on in the web build for every user of it,** which costs frame time and DOM nodes, and no key narrows it to a test build. Weigh it before you turn the key on in an app whose web build you ship.

**`maestro:`** says what the flows open. These are all the keys:

```yaml
fespalier:
  semantics_ids: true # required by `fsp maestro`
  maestro:
    app_id: com.example.shop # Android and iOS: each flow's `appId:`   } exactly one
    url: http://localhost:8080 # the web: each flow's `url:`             } of the two
    link: myshop://shop.example.com # what a route's path is appended to; default below
    out: .maestro/routes # default; a folder inside the project, no `..`
    guard_flow: .maestro/sign-in.yaml # optional: runs before the link of a guarded route
    timeout: 20000 # default; how long a flow waits for the page, 1000 to 600000 ms
    samples: # the value of each dynamic folder, inherited by the routes below it
      products/$id: 2
      greet/$name: Ada
      docs/$$rest: [guides, intro] # a catch-all takes a list of parts (a lone value is one part)
```

- `app_id`, `url` and `link` may be a Maestro variable written whole, such as `app_id: ${APP_ID}`; it is copied into the flow as written, and `maestro test -e APP_ID=com.example.shop` fills it in.
- **`link`** is what a route's path goes after: `myshop://shop.example.com` plus `/products/2`. It defaults to the `url` for the web. For an app it comes from [`links:`](cli.md#deep-links-and-a-sitemap-fsp-links) (`<scheme>://<first domain>` with a `scheme`, else `https://<first domain>`), and with neither it is an error. A Flutter web app on the default **hash URL strategy** needs `link: http://localhost:8080/#`, because its routes live after the `#`; with `usePathUrlStrategy()` the default is right.
- **`samples`** keys are folders as `fsp routes` prints them without `/page.dart` (`products/$id`, `(members)/notes/$id`), and each must be a `$x`, `$$x` or `$$$x` folder.
  - A value is text, a number, a boolean or, for a catch-all, a list of them. It is percent-encoded and checked against the segment's type (`int`, `double`, `num`, `bool`, and `List` of them); a `String`, a `DateTime` or an enum is taken as written, because the generator doesn't know an enum's values.
  - The sample is for the _folder_, so every route below `products/$id` opens `/products/2/...`.
  - An optional catch-all (`$$$path`) with no sample is the bare path.
  - Quote a value that must stay text (`'1.10'`).

`fsp maestro` writes one flow per route into `out` (commit it, like `app.g.dart`). This is the shop example's, `examples/shop/.maestro/routes/product_route.yaml`:

```yaml
# Written by `fsp maestro` from lib/app/products/$id/page.dart: don't edit it, run `fsp maestro` again.
url: "http://localhost:8080"
name: "/products/:id"
tags:
  - "fespalier"
---
- launchApp
- openLink: "http://localhost:8080/#/products/1"
- extendedWaitUntil:
    visible:
      id: "route:/products/:id"
    timeout: 20000
```

- `launchApp` starts the app afresh, so every flow begins from the same state.
- `openLink` opens the route's sample URL (the long form with `autoVerify: true` for an Android app whose link is `https`, which skips Android's "Open with" dialog).
- `extendedWaitUntil` returns the moment the identifier is on the screen, or fails after `timeout`. When it returns, the route's guards ran, its data loaded and its page was built.
- A guarded route's flow also has `- runFlow: "../sign-in.yaml"` between `launchApp` and `openLink` (the path is relative to the flow) and a comment naming the `guard.dart` files.

**Which routes get a flow.** The rows are checked in this order, and the first that applies wins. Every skip is printed, on every run, and none of them fails `--check`.

| Route                                          | Result  | Printed                                                                                                               |
| ---------------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------- |
| A `redirect.dart` route                        | skipped | `skipped /old: a redirect, with no page to see`                                                                       |
| `app_id`, and `const linkable = false;`        | skipped | ``skipped /secret: `const linkable = false;`, so `fsp links` does not open the app at it``                            |
| A `$x` or `$$x` segment with no sample         | skipped | ``skipped /products/:id: no sample for products/$id in `fespalier.maestro.samples` ``                                 |
| A `guard.dart` at or above it, no `guard_flow` | skipped | ``skipped /checkout: guarded by checkout/guard.dart; set `fespalier.maestro.guard_flow` to a flow that gets past it`` |

A `(group)` folder's guard covers the routes in it. Samples come from the pubspec only. Layouts, not-found views, query parameters and the localized spellings get no flow: a route is opened at its canonical path.

**Files and ownership.** A flow is named after its typed route class in snake case: `ProductRoute` is `product_route.yaml`, `ProPlanRoute` is `pro_plan_route.yaml`, the root `HomeRoute` is `home_route.yaml` (the `_route` ending keeps a file from being Maestro's `config.yaml`).

- Every file `fsp maestro` writes starts with ``# Written by `fsp maestro` ``. In `out`, a `*.yaml` file with that first line is `fsp`'s: `fsp maestro` deletes it when no route needs it any more, and `--check` reports it. Any other file there (a flow you wrote, a `config.yaml`) is never read or touched, so hand-written journeys live beside the generated ones.
- The output is a function of the tree and the pubspec (a fixed order, no dates), so `fsp maestro --check` writes nothing and exits non-zero when a flow is missing, out of date or no longer a route's, and names it. Run it next to `fsp check`: it does not check that `lib/app.g.dart` is current.
- The values of `maestro:` are checked only by `fsp maestro`, so a mistake there never stops `fsp gen`.

**Running them.** `maestro test .maestro/routes`. Pass the folder, not `.maestro`: Maestro runs only the top-level flows of the folder it is given, and skips subfolders unless a `config.yaml` there lists them (`flows: ["routes/*"]`). `maestro test -e APP_ID=... -e URL=...` fills in variables.

- **The web.** Maestro's web support is in beta. Serve the app at the `url` (`flutter run -d web-server --web-port 8080`, or a static server for `flutter build web`; with the path strategy it must serve `index.html` for unknown paths) and run the flows. `openLink` navigates the browser, which reloads a Flutter web app. Maestro 2.7.0 or later reads `id:` from `flt-semantics-identifier`, the attribute Flutter's web engine writes for `Semantics(identifier:)`.
- **Android and iOS.** The app must open the link: Android needs the intent filters, iOS the associated domains or the URL scheme, which [`fsp links`](cli.md#deep-links-and-a-sitemap-fsp-links) writes (paste them in, as it says). iOS may ask "Open in ...?" before a custom scheme opens the app; the generated flows do not answer it, so prefer an `https` link or start the run with a flow of your own. On iOS the flows have not been verified: if one waits and times out on a page you can see, check that first.
- **A guard flow** runs after `launchApp` and before `openLink`: write the sign-in once (`.maestro/sign-in.yaml`), give it as `guard_flow`, and every guarded route's flow runs it first. On the web `openLink` reloads the app, so the sign-in has to survive a reload (a stored token, not in-memory state), or the guard will send the flow back to the login page.

**In CI.** To gate a pull request without Maestro, replay the flows in a browser: [Development](development.md) describes the Playwright replay of the shop's flows (`scripts/check-web-routes.sh <example>` with `ci/web-routes/` is a template for an app's own CI). To run Maestro itself, build and serve the web app, then run the flows and `fsp maestro --check`. Maestro's web driver follows Chrome and has broken on Chrome upgrades before, so pin the Maestro version, check the download's sha256, and do not make it the only gate.

```yaml
- run: fsp maestro --check
- run: curl -fsSL "https://get.maestro.mobile.dev" | bash
- run: flutter build web --release --no-web-resources-cdn
- run: python3 -m http.server 8080 --directory build/web &
- run: maestro test --headless .maestro/routes
```

## Route smoke tests (`fsp test`)

Since 0.8.1. `fsp test` writes a widget smoke test for every route, into one file, `test/routes/routes_test.dart`. Each test opens the route at a sample URL with `pumpRouter`, waits until its page is on screen, and expects exactly one. It proves what a [Maestro flow](#maestro-flows-fsp-maestro) proves (the route exists, its guards let it through, its data loaded, its page was built) in `flutter test`, on the VM, with no device and no browser. `fsp test` does not run Flutter: it writes the file, or with `--check` compares it, as `fsp maestro` does. `examples/shop/test/routes/routes_test.dart` is what it wrote there; this is its first test:

```dart
testWidgets(
  '/products/:id at /products/1',
  (tester) => smokeTestRoute(
    tester,
    '/products/:id',
    AppRoutes.router(
      initialLocation: '/products/1',
    ),
    overrides: setup.overrides(
      '/products/:id',
    ),
  ),
);
```

**What a test does.** `smokeTestRoute` (in `package:fespalier/testing.dart`) runs these steps:

1. `pumpRouter(..., settle: false)`, which also loads the code of every deferred route first.
2. It pumps 100 ms of the test's **fake** clock at a time until the page is on screen. A `data.dart` fake that answers after a delay is waited out, and nothing waits on the real clock.
3. It fails after `timeout` (30 s of fake time by default) with `The page of /items is not on screen after 30000 ms of fake time: the router is at /sign-in. A guard that redirects, a data.dart that fails or never completes, or an exception while building (above) keeps it away.` Those are what keeps the page away (Flutter prints a build exception above); the location says where the router ended.
4. It expects exactly one page, takes the tree down, and runs the clock `timeout` on, so a fake's pending one-shot timer fires with no widget left to react and the test does not end with "A Timer is still pending". A _periodic_ timer in a fake still fails the test, which is the right signal.

**How the page is found.** With [`semantics_ids: true`](#maestro-flows-fsp-maestro) the test looks for the page's `Semantics(identifier: 'route:<pattern>')` with `findRoutePage(pattern)`; it needs no semantics tree, and a page underneath another is off screen and not found. Without it, a class page is found by its type (`find.byType`), and the test file imports the page's library; a function page has no type to find, so it is skipped (printed below). To find a page some other way in a hand-written test, pass `page:` to `smokeTestRoute`.

**The file and who owns it.**

- The file's first line is ``// Written by `fsp test` from lib/app/: don't edit it, run `fsp test` again.`` and `fsp test` writes only that file. It never overwrites a file of that name that does not start with the marker: it fails and says so (move your file, or set `out`).
- The output is a function of the tree and the pubspec (route-table order, no dates), so `fsp test --check` writes nothing and exits non-zero when the file is missing or out of date.
- The second line is `// dart format off`. The file is laid out to need no formatting: a call is split one argument to a line, each with a trailing comma, which is what `dart format` leaves alone under an SDK older than 3.7; under 3.7 and later the marker holds the formatter off. Either way `dart format --set-exit-if-changed` is clean on it.

**`test:`** has these keys, all optional. `fsp test` works with no `test:` section at all:

```yaml
fespalier:
  test:
    out: test/routes # default; `test`, `integration_test` or a folder below one
    setup: test/routes/setup.dart # default: <out>/setup.dart, used when it exists
    timeout: 30000 # default; milliseconds of the fake clock a test waits for its page, 1000 to 600000
    samples: # default: `maestro.samples`; same format
      products/$id: 1
    skip: [/admin] # patterns as `fsp routes` prints them
```

**Samples** are the values of the dynamic folders, in the format of [`maestro.samples`](#maestro-flows-fsp-maestro). When `test.samples` is not there, `maestro.samples` is used (only that key of `maestro:` is read, so a `maestro:` section that `fsp maestro` would refuse does not stop `fsp test`). With neither, a route with a dynamic segment is skipped. A sample is percent-encoded and checked against the segment's type, with the same messages as Maestro's, naming `fespalier.test.samples` or `fespalier.maestro.samples`, whichever is in use.

**The setup file** is yours: `test/routes/setup.dart` by default, or `test.setup`. `fsp test` only reads which of two top-level functions it exports, and imports it as `setup` into the test file:

```dart
// test/routes/setup.dart
import 'package:fespalier/testing.dart';

/// Called once per test, so every test gets fresh fakes.
List<Override> overrides(String pattern) => [
  apiProvider.overrideWithValue(FakeApi()),
  // checkout/guard.dart sends an empty cart back to /cart: this one has a line.
  if (pattern == '/checkout') cartProvider.overrideWith(_FullCart.new),
];

/// Optional: the app around the router, for an app that needs its theme or localizations.
Widget app(GoRouter router) => MaterialApp.router(routerConfig: router, theme: appTheme);
```

- `List<Override> overrides(String pattern)` is called once per test with the route's pattern. It returns the providers that test boots with (`package:fespalier/testing.dart` exports riverpod's `Override` since 0.8.1), and it can vary by route: a signed-in user for a guarded route.
- `Widget app(GoRouter router)` builds the app around the router; the default is `MaterialApp.router(routerConfig: router)`. `pumpRouter` takes the same `app:` since 0.8.1.
- Each takes exactly one required positional parameter. A setup file with neither, or with one that takes another shape, is an error that says what to write.
- A route with a `guard.dart` at or above it is skipped when there is no `overrides`, because the guard would most likely redirect. With `overrides` it gets a test, and a guard that still redirects fails it, naming where the router ended.

**Which routes get a test.** Each is checked in this order, and the first that applies wins. Every skip is printed on every run (and listed in the test file's header), and none of them fails `--check`.

| Route                                             | Result  | Printed                                                                                                                             |
| ------------------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| A `redirect.dart` route                           | skipped | `skipped /old: a redirect, with no page to see`                                                                                     |
| Listed in `test.skip`                             | skipped | ``skipped /admin: listed in `fespalier.test.skip` ``                                                                                |
| A `$x` or `$$x` segment with no sample            | skipped | ``skipped /products/:id: no sample for products/$id in `fespalier.test.samples` ``                                                  |
| A `guard.dart` at or above it, and no `overrides` | skipped | ``skipped /checkout: guarded by checkout/guard.dart; give test/routes/setup.dart an `overrides(String pattern)` that gets past it`` |
| A function page, and no `semantics_ids`           | skipped | ``skipped /fn: a function page; set `semantics_ids: true` so its test can find it``                                                 |

A route with `const linkable = false;` is tested: the test runs in the process, not through a link. Each route is opened at its canonical path (query parameters and localized spellings are not tried). The success lines are `✓ test: 6 routes in test/routes/routes_test.dart` (with `; 1 route skipped` when there are skips, and `(unchanged)` when nothing was written) and, for `--check`, `✓ test: test/routes/routes_test.dart is up to date (6 routes)`. The values of `test:` are checked only by `fsp test`, so a mistake there never stops `fsp gen`.

**In CI**, next to `fsp check`:

```yaml
- run: fsp test --check
- run: flutter test
```
