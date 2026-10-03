# Route lifecycle: `observe.dart`

Since 0.8.0. The README's [Route lifecycle](https://github.com/vaam-apps/fespalier#route-lifecycle-observedart)
section is the user documentation; this page is what an agent needs to get a hook right and to explain one
that misbehaves.

## When a hook fires

A watch on the router compares what it **committed** with what it showed before, at the end of the first
frame that shows the change (a post-frame callback). A **page instance** is one page on a navigator: a
tree page is identified by its route plus its **matched location**, a pushed page by its own key plus
the path it shows. The visible page is the top one: the last pushed page, else the leaf of the router's
location. At the end of a frame, after a commit:

1. **leave**: every entered instance that is on no navigator, newest first. An instance in a tab layout
   branch that is not the current branch, while the tab layout is still on screen, is **parked**, not
   gone.
2. then, if the visible page was never entered: **enter**; if it was entered but was not the visible page
   at the last comparison: **focus**.

So `onEnter` and `onLeave` are paired, `onFocus` only falls between them, and:

- `go('/a/1')` then `go('/a/2')`: leave `/a/1`, enter `/a/2`. A query change fires nothing.
- A page covered by a nested page (`/a` under `/a/1`) is **not left**; it enters later if it becomes the
  visible page (a deep link to `/a/1` enters `/a/1` only).
- Switching tabs enters the other tab's page and parks the first; switching back focuses it. Going to a
  **different** page of the parked tab leaves the old one.
- `push('/x')`, then `pop()`: enter `/x`, then leave `/x` and focus the page below.
- A `go` that a guard redirects: only the final location's events. The redirected-from location never
  committed.
- A `go` out of a tab layout leaves every entered page of every tab, newest first.
- A location that matches no route (or whose segments don't parse): no hooks; the previous page leaves.
- Several commits before one frame (a redirect chain, a hook that navigates) are one comparison.
- Nothing fires when the router is disposed or the app is killed.

## What a hook is given

The hooks of a page are looked up from its location through the generated `RouteMatcher.observe`
(`AppRoutes._observeAt`), and bound **when the page enters**: `onLeave` gets the segments the page
entered with. `onFocus` is bound again, with the current location.

The `Ref` is that of a **throwaway `Provider.autoDispose`**, closed as soon as the hook returns. Riverpod
forbids changing a provider while another is being built, so the hook runs once that provider has
finished building: `ref.read(views.notifier).add(...)` works. `ref.watch` has nothing to keep alive.
Reading a provider that is not overridden in a test uses the app's default: override it in `pumpRouter`.

## Errors

A hook that throws is caught and reported with `FlutterError.reportError(FlutterErrorDetails(...))`:
library `fespalier`, context `while running onEnter of products/$id/observe.dart` (the hook and the file
filled in). The hooks after it still run. In an app `otel_zone`'s `FlutterError.onError` reports it; in a
widget test it fails the test.

## Binding, as the generator sees it

`observe.dart` is bound like a `guard.dart`, with these differences: the return type must be `void`; the
`route` parameter is `TypedLocation`; `extra`, `ProviderContainer` and `WidgetRef` are errors; the file
needs one of the three functions; and a page-less folder's query parameters belong to the hook alone. The
diagnostics, with their exact text, are in
[`diagnostics-observability.md`](../../fespalier-troubleshooting/references/diagnostics-observability.md).
`fsp routes` tags a page that has hooks above it with `observe` (`--json` `tags`, and the `markers` of the
route tree DevTools reads).

## Testing

```dart
// a widget test of an app with hooks
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/analytics.dart';
import 'package:my_app/app.g.dart';

void main() {
  testWidgets('a product enters and leaves', (tester) async {
    final router = AppRoutes.router(initialLocation: '/products/1');
    final container = await pumpRouter(tester, router);
    router.go('/products/2');
    await tester.pumpAndSettle(); // hooks fire after the frame
    expect(container.read(views), contains('left product 1'));
  });
}
```

`pumpRouter` keeps working: hooks add no timer and need no `runAsync`.

## Not built

No hook for layouts or sections, no `onCover`/`onBlur`, and no veto: `onLeave` cannot stop a navigation
(that is go_router's `GoRoute.onExit`, which fespalier does not wrap).
