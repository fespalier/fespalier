# Shortcuts and home-screen widgets: fespalier_launch

Since 0.18.0. A home-screen shortcut or a widget tap opens a typed route: the action that cold-starts the app is the router's initial location, and an action while the app runs is a `go` (or a `push`), both marked `NavigationSource.shortcut` or `NavigationSource.widget`. `docs/launch.md` is the page; `references/launch-sources.md` has the recipes for quick_actions and home_widget. It is an [adapter](../../fespalier/references/app-main.md): `adapters: [fespalier_launch]` under `fespalier:`, and a dependency on `fespalier_launch` with the same git `url` and `ref` as `fespalier`.

## The three things an app writes

1. One `LaunchSource` per launcher plugin (the recipes: quick_actions for shortcuts, home_widget for widgets). **The package depends on no launcher plugin**; a `LaunchSource` is `initialAction()` (the action that opened the app, answered once) and `actions` (the taps while the app runs).
2. A `LaunchRoute`, `LaunchTarget? Function(LaunchAction)`: a `switch` over the two kinds of action. A shortcut is matched by its `type` against your own constants, and a widget's URI goes through `widgetLinkRoute(schemes:, hosts:, matches:)`, which accepts an in-app path and refuses anything else.
3. One call in `main()`, **before `AppMain.run()`**: `FespalierLaunch.configure(sources:, route:)`. `launch()` runs before any `ProviderScope`, so a provider override cannot carry these. With `main: manual`, before `AppAdapters.zone`.

```dart
// in lib/main.dart (AppRoutes and AppMain are your generated app.g.dart and app.main.g.dart)
import 'package:fespalier_launch/fespalier_launch.dart';
import 'app.g.dart';
import 'app.main.g.dart';

Future<void> main() {
  FespalierLaunch.configure(
    sources: [QuickActionsLaunchSource(), HomeWidgetLaunchSource()], // see launch-sources.md
    route: launchRoute,
  );
  return AppMain.run();
}
```

## Behaviour to rely on, and traps

- **A cold start is `launch()`.** Every source is asked, in the order listed, and the first non-null answer wins; the answer is an `InboundLaunch(location, source: shortcut or widget, extra:)`, so the router is built at that location. A sync source stays sync; a `Future` from one source is awaited and delays the first frame, so `initialAction()` is a local read. `LaunchOpen.push` is ignored on a cold start.
- **A warm action is `attach(router, container)`.** One `container.listen` per source, closed with the `ProviderScope`; `router.go` or `router.push` inside `navigateFrom(source, ...)`. **The guards run**: a signed-out shortcut to a guarded page lands on the login page with `from`.
- **The startup hold** (since 0.18.0). An action said while the app starts (between `launch()` and `attach`) is kept: the **latest** across all sources (one, never a queue, no timer), and opened once, as a warm action, after the first frame. `attach` subscribes the scope before it ends the hold, so nothing is lost in between.
- **The cold-start action is not opened twice.** The action that `launch()` opened is dropped once when the stream says it again during startup, by **equality** (a shortcut by its `type`, a widget by its `uri`, never by `raw`). An equal action after `attach` is a new one and opens. A different action during startup opens.
- **Equality is by type or by URI.** Two `ShortcutAction('a')` are the same action; a `ShortcutAction` and a `WidgetAction` never are.
- **Untrusted input.** On Android any app can start the launcher activity with an extra or a URI, and any app can start one of your shortcuts by its type. Never navigate to a string an action carries: map it with a `switch` on your constants, and a widget's URI through `widgetLinkRoute`, which refuses an empty URI, a foreign scheme or host, credentials, a path that does not start with one `/`, a control character, a backslash, a decoded `//`, and a path `matches` rejects. The host, port and fragment are dropped, the query is kept.
- **One subscription per `ProviderScope`.** A second router built on the same container is ignored; the first router gets the actions.
- **Unconfigured**: one `FlutterError` reports ``fespalier_launch is listed under `fespalier: adapters:` but was never configured: call FespalierLaunch.configure(sources: [...], route: ...) in main() before AppMain.run()``; the adapter then does nothing and never throws. `AppMain.root()` in a widget test runs no `main()`: call `configure` in the test (`sources: const []` opens nothing).
- **No `onEnter`, no `overrides()`.** The adapter has neither, so `AppAdapters.handlesEnter` stays false and go_router keeps its synchronous parsing. The actions reach the app through private providers, so no provider override is needed.
- **On the web `launch()` is never asked**, and a shortcut or a widget opens the app as an ordinary URL.
- **Telemetry**: `fespalier.launch.open` with `fespalier.launch.state` (`cold` | `warm`), `fespalier.launch.kind` (`shortcut` | `widget`) and `fespalier.launch.routed` (bool), plus `fespalier.navigation.source` on the navigation. A shortcut type, a widget URI, a path, a query, an id and the plugin's text are never reported (`FespalierLaunchConventions`, pinned by the package's `telemetry_test.dart`).
- **Widgets and platform links.** With Flutter's deep linking on, a widget's URI can also reach the router as a platform link. A launch wins on a cold start (it sets `overridePlatformDefaultLocation`). Whether the URI also arrives as a link is UNCHECKED (below): so give the widget the in-app location as its path (`myapp:///orders/42`) and map it with `widgetLinkRoute`.

**What no test shows (UNCHECKED), never stated as fact.** No CI job runs a launcher; the fakes prove the wiring only. Each is to be checked on a device before a release:

1. quick_actions, Android cold start: expected to reach the handler inside `initialize()`, so the initial location.
2. quick_actions, iOS cold start: either buffered before `initialize` (cold) or sent later through the startup hold (warm, after the first frame, with home shown briefly). Unknown per iOS version and under UIScene.
3. quick_actions warm taps, on both platforms, expected on `actions`.
4. home_widget cold start: `initiallyLaunchedFromHomeWidget()` expected to answer before the first frame, on Android and iOS.
5. home_widget warm taps: expected on `widgetClicked` (on Android possibly through `onNewIntent` only while the EventChannel is listened to).
6. The widget's URI as a platform link: on a warm tap that could mean two navigations (`link` and `widget`) to the same place, in an unknown order; on iOS a cold start may add a later `link` navigation.
7. Hot restart: home_widget answers the launch intent again, so the widget's target opens again (development only).

## Testing

`package:fespalier_launch/testing.dart` has `FakeLaunchSource` (`initial:`, `initialReads`; `shortcut(type)`, `widget(uri)`, `act(action)`, `fail(error)`, `close()`). The package's own `widgetLinkRoute` rules are tested the same way, with a route whose `matches` takes everything, so only the URI rules refuse:

```dart
// test/launch_route_test.dart
import 'package:fespalier_launch/fespalier_launch.dart';
import 'package:fespalier_launch/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final route = widgetLinkRoute(
    schemes: {'myapp'},
    hosts: {'shop.example.com'},
    matches: (uri) => uri.path.startsWith('/orders/'),
  );
  String? at(Uri uri) => route(WidgetAction(uri))?.location;

  test('an in-app URI and an https URL on our host', () {
    expect(at(Uri.parse('myapp:///orders/42')), '/orders/42');
    expect(at(Uri.parse('myapp:///orders/42?tab=2#x')), '/orders/42?tab=2');
    expect(at(Uri.parse('https://shop.example.com/orders/42')), '/orders/42');
  });

  test('anything else is refused, never opened', () {
    for (final bad in [
      'evil:///orders/1',
      'http://shop.example.com/orders/1',
      'https://other.host/orders/1',
      'myapp://orders/1',
      'https://u:p@shop.example.com/orders/1',
      'myapp:////evil.com',
      'myapp:///orders/%5C1',
      'myapp:///nowhere',
    ]) {
      expect(at(Uri.parse(bad)), isNull, reason: bad);
    }
    expect(route(const ShortcutAction('last_order')), isNull);
  });

  test('FakeLaunchSource answers its initial action once', () {
    final source = FakeLaunchSource(initial: const ShortcutAction('last_order'));
    expect(source.initialReads, 0);
    expect(source.initialAction(), const ShortcutAction('last_order'));
    expect(source.initialAction(), isNull);
    expect(source.initialReads, 2);
  });

  test('a shortcut and a widget with the same text are different actions', () async {
    final source = FakeLaunchSource();
    final seen = <LaunchAction>[];
    final sub = source.actions.listen(seen.add);
    source.shortcut('a');
    source.widget(Uri.parse('myapp:///a'));
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen, [const ShortcutAction('a'), WidgetAction(Uri.parse('myapp:///a'))]);
    await source.close();
  });
}
```

A widget test of the whole path boots `AppMain.root(router: () => AppRoutes.router(launch: launch))` after `FespalierLaunch.configure(sources: [fake], ...)` and `final launch = await AppAdapters.launch()`, then `fake.shortcut(...)` and `pumpAndSettle()`; `examples/plugins/test/launch_test.dart` is the model. Call `FespalierLaunch.debugReset()` in `setUp` and `tearDown` (it also ends the hold that `launch()` started).
