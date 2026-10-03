# Maestro: semantics identifiers and smoke flows (since 0.7.0)

[Maestro](https://docs.maestro.dev) tests an app from outside, on a device, an emulator or in a browser.
It reads the platform's accessibility tree, so it **cannot see a Flutter `Key`**: `find.byKey` and
`ValueKey('x')` mean nothing to it. It finds text, a `Semantics` label and, since Flutter 3.19, a
`Semantics(identifier: 'x')`, which its `id:` selector matches. Widget tests (`pumpRouter`) stay the
tool for logic and states; Maestro is for real devices, the web and journeys across routes.

fespalier gives every page an identifier and writes a smoke flow per route. This page is the contract,
the test that proves it, and the traps. The commands and keys are in
`fespalier`, `references/cli-and-config.md` (`fsp maestro`), the messages in
`fespalier-troubleshooting`, `references/diagnostics-config-and-meta.md`.

## The identifier contract

With `semantics_ids: true` in the `fespalier:` section of `pubspec.yaml` (then `fsp gen`), the
generated router wraps **each page's own widget call** in
`Semantics(identifier: 'route:<pattern>', container: true, child: ...)`.

- **`<pattern>` is what `fsp routes` prints**: `route:/`, `route:/products/:id`, `route:/docs/*rest`,
  `route:/files/*path?`. It depends only on the folder path: the same for every localized spelling and every
  `AppRoutes.mount(at:)` prefix, and not changed by renaming a class. A `(group)` adds nothing.
- **It is in the tree if and only if the route's own page is built.** The wrapper is inside `DataView`,
  `DeferredView` and `SectionView`, so while `loading.dart` shows (a deferred page's code included), when `error.dart` shows, and for `not_found.dart`
  (an unparsable segment, `/products/abc`) there is **no** identifier. A smoke flow that waits for it
  cannot pass on a spinner.
- **Not on a page underneath.** go_router builds the whole matched stack, but only the top page is on
  screen: at `/products/1`, `route:/products/:id` is there and `route:/products` is not.
- **Only `page.dart`.** A layout, a shell, a `redirect.dart` and a not-found view carry none.
- **Never `const`.** `Semantics` has no `const` constructor; a `const` page keeps its own `const` inside
  the wrapper. `container: true` adds a node with no label and no action.
- **With the key off (the default) the generated file has none of this**, byte for byte.
- **On the web** the generated `mount()` also calls `ensureWebSemantics()`, because Flutter web builds no
  semantics tree until a screen reader asks and Maestro finds nothing without one. It turns it on once,
  for good, and **it stays on for every user of that web build**: more DOM and frame time. Off the web
  and in every widget test it does nothing.

## Testing it

`find.bySemanticsIdentifier` needs the semantics tree: take a handle with `tester.ensureSemantics()` and
**dispose it in the test body**, before the test ends (`addTearDown` runs after the binding checks for a
leftover handle, and the test fails with "A SemanticsHandle was active at the end of the test").
`pumpRouter` settles for you; the page is only there once its data is.

```yaml
# pubspec.yaml
fespalier:
  semantics_ids: true
```

```dart
// lib/app/products/$id/page.dart
import 'package:flutter/material.dart';

class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) => Text('Product $id');
}
```

```dart
// test/semantics_test.dart
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';

void main() {
  testWidgets('the page wears its route identifier', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpRouter(tester, AppRoutes.router(initialLocation: '/products/1'));
    expect(find.bySemanticsIdentifier('route:/products/:id'), findsOneWidget);
    handle.dispose();
  });
}
```

To look at the wrapper without the semantics tree, match the widget:
`find.byWidgetPredicate((w) => w is Semantics && w.properties.identifier == 'route:/')`. To prove a
loading view carries none, boot with `settle: false` and `pump` once.

## The traps

- **A `Key` is invisible to Maestro.** Give a widget Maestro must tap a text, a `Semantics(label:)` or
  `Semantics(identifier:)` of its own; fespalier only names the pages.
- **A flow that passes on a spinner** means the identifier is on something else: only the page itself
  wears it (see above), so a hand-written flow should wait for `id: "route:<pattern>"`, not for text that
  a loading view might also show.
- **The hash strategy needs `link: http://localhost:8080/#`.** Flutter web's default URLs are
  `/#/products/1`; without the `#` the flow opens a path the server knows nothing of.
- **`maestro test .maestro` does not run `routes/`.** Maestro runs only the top-level flows of the folder
  it is given, and a `config.yaml` there must list subfolders (`flows: ["routes/*"]`). Pass
  `.maestro/routes`.
- **The guard flow and the web reload.** A guarded route's flow runs `guard_flow` after `launchApp` and
  before `openLink`. On the web `openLink` navigates the browser, which reloads the app: a sign-in kept
  only in memory is gone, and the guard redirects the flow to the login page.
- **`ensureWebSemantics` stays on** in a web build: weigh the cost before turning `semantics_ids` on in
  an app whose web build ships.
- **`maestro:` needs `semantics_ids: true`**, and a stale `app.g.dart` has no identifiers: run `fsp gen`
  after changing the key.

## In CI (since 0.8.1)

fespalier's own CI replays the shop's flows without Maestro: the `web-routes` job builds `examples/shop`
for the web, serves it, and a pinned Playwright opens each flow's `openLink` in Chromium, with every
request that is not to the local server blocked, and waits for the flow's `id:` as the DOM attribute
`flt-semantics-identifier` (`scripts/check-web-routes.sh`, `ci/web-routes/`, `just web-routes`). Copy
those two for an app's own CI when Maestro's web driver is too brittle to gate on.

To run Maestro itself, build with `flutter build web --release --no-web-resources-cdn` (CanvasKit is
bundled, no CDN), serve it at the flows' `url`, and run `maestro test --headless .maestro/routes`. Maestro
2.7.0 or later reads `id:` from `flt-semantics-identifier`. Its web driver follows Chrome and has broken on
Chrome upgrades (fixes in its 2.1.0, 2.2.0 and 2.9.0), so pin the version, check the download's sha256,
and keep it out of the required checks: fespalier's `maestro-web.yml` runs it weekly and on demand only.

## Not built, and not verified

- **Verified:** the identifier in widget tests (`find.bySemanticsIdentifier`), the flows as golden files,
  and (since 0.8.1) on the web, that each committed flow's link opens its route in Chromium and the
  identifier is in the DOM (`web-routes`). **Not verified:** the same on iOS. A flow that times out on a
  page you can see: check that first.
- **Not built:** a `link:` identifier on `RouteLink`, `samples` in `meta.dart`, a flow for a layout, a
  not-found view, a query parameter or a localized spelling.
