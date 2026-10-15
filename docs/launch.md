# Shortcuts and home-screen widgets: fespalier_launch

`fespalier_launch` (since 0.18.0) makes a home-screen shortcut or a widget tap open a typed route: the action that **cold-starts** the app is the router's initial location, and an action while the app **runs or sits in the background** is a navigation, both marked `source=shortcut` or `source=widget` in [telemetry](observability.md#telemetry). It is an [adapter](adapters.md): you list it under `fespalier: adapters:`, and the generated `main()` calls it.

It is the routing half of the launcher, and only that. Where an action comes from is a `LaunchSource` that you hand to it, one per plugin you use. **The plugins are not dependencies**: quick_actions (shortcuts) and home_widget (widgets) are compiled recipes in the `fespalier-routing` skill, so an app that uses neither does not link them. The package never sets a shortcut item, never saves widget data and never updates a widget: what the home screen shows is the app's.

## Install

Add `fespalier_launch` under `dependencies:` next to `fespalier`, with the same git `url` and the same `ref`: pub resolves the two to one package only if they are the same repository dependency. The snippet, kept at the release's tag, is in [`packages/fespalier_launch/README.md`](../packages/fespalier_launch/README.md). Then list it as an adapter and run `fsp gen`:

```yaml
# pubspec.yaml
fespalier:
  telemetry: true # optional: reports the navigation's source
  adapters: [fespalier_launch]
```

Any `onEnter` makes go_router parse every navigation asynchronously, and `fespalier_launch` has none: it answers `launch()` and `attach()`, and the router keeps go_router's synchronous parsing (since 0.18.0; see [Adapters in the generated `main()`](adapters.md#adapters-in-the-generated-main)). `AppAdapters.handlesEnter` stays false for an app that lists only this package.

## Configure

An adapter takes no options from the pubspec, and `launch()` runs before any `ProviderScope` exists, so the app's own code reaches it through one static call in `main()`, before `AppMain.run()` ([Adapters that need your code](adapters.md#adapters-that-need-your-code)):

```dart
// lib/main.dart
Future<void> main() {
  FespalierLaunch.configure(
    sources: [QuickActionsLaunchSource(), HomeWidgetLaunchSource()],
    route: launchRoute,
  );
  return AppMain.run();
}
```

- `sources` is a list of `LaunchSource` (below), de-duplicated by identity, in the order you list them. `route` maps an action to a place. An empty list is allowed: nothing opens.
- Calling `configure` twice replaces (a hot restart runs `main()` again).
- **Unconfigured, the adapter says so once and does nothing**: one `FlutterError` reports ``fespalier_launch is listed under `fespalier: adapters:` but was never configured: call FespalierLaunch.configure(sources: [...], route: ...) in main() before AppMain.run()``, and `launch()` and `attach()` do nothing. It never throws out of them: an adapter must not stop an app from starting.
- With `main: manual`, call `configure` in your own `main()` before `AppAdapters.zone`.

A `LaunchSource` is what a launcher plugin gives the package:

| Member            | What it is                                                                                                                                                                                                                                                                                                                                        |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `initialAction()` | The action that cold-started the app, answered once (a second call answers null). A local read (in the recipes, the shortcut quick_actions hands its `initialize` handler, or home_widget's `initiallyLaunchedFromHomeWidget`): it runs before the first frame, so a `Future` delays that frame by one channel round trip. Every source is asked. |
| `actions`         | The actions taken while the app runs or sits in the background. A broadcast stream, listened to once per `ProviderScope` and, from `launch()` until the scope's own subscription exists, once more (the startup hold). A source on a platform channel returns the same stream every time (a `late final` field).                                  |

The recipes for quick_actions and home_widget, with the floors of each plugin, are in [`references/launch-sources.md`](../skills/fespalier-routing/references/launch-sources.md).

## Mapping an action

`LaunchRoute` is `LaunchTarget? Function(LaunchAction action)`: a `LaunchTarget(location, extra:, open:)` (or `LaunchTarget.to(OrderRoute(id: 42))`) to open, or `null` to open the app and navigate nowhere. `LaunchAction` is a sealed class with two kinds, so the mapping is an exhaustive `switch`:

```dart
final widgetRoute = widgetLinkRoute(
  schemes: {'myapp'},
  hosts: {'shop.example.com'},
  matches: (uri) => AppRoutes.matchUrl(uri) != null,
);

LaunchTarget? launchRoute(LaunchAction action) => switch (action) {
  ShortcutAction(type: 'last_order') => LaunchTarget.to(const OrderRoute(id: 42)),
  ShortcutAction(type: 'account') => LaunchTarget.to(const AccountRoute()),
  ShortcutAction() => null,
  WidgetAction() => widgetRoute(action),
};
```

- `LaunchOpen.go` (the default) replaces the stack, as a link does; `LaunchOpen.push` goes on top of the current page. A cold start is always the initial location, whatever `open` says.
- A `ShortcutAction` has a `type` (the string you gave the shortcut item) and a `raw` (quick_actions' own object, for your mapping only). A `WidgetAction` has a `uri` (the URI the widget opened the app with) and a `raw`. Equality is by `type` or by `uri`, never by `raw`.
- A mapping that throws is reported and counts as `null`. It must be quick and synchronous: a cold start runs it before the first frame.
- **An action is untrusted input.** On Android any app can start the launcher activity with an extra or a URI, and any app can start a shortcut of yours by its type. Map a shortcut by a `switch` on your own constants, as above, and never navigate to a string the action carries.

`widgetLinkRoute(schemes:, hosts:, matches:, open:)` is the common mapping for a widget. A widget opens the app at a URI whose path is the in-app location, so `myapp:///orders/42` opens `/orders/42`. The URI is kept only when all of these hold:

- its scheme is `https` with a host in `hosts`, or a scheme in `schemes` whose host is empty or in `hosts`; anything else (an empty URI, `http`, a foreign scheme or host) is refused;
- it has no credentials;
- its path starts with one `/` and not with `//`, and once decoded it has no control character, no backslash and no `//` at its start;
- `matches` accepts the path (pass `(uri) => AppRoutes.matchUrl(uri) != null`).

The host, the port and the fragment are dropped; the query is kept (`myapp:///orders/42?tab=2#x` opens `/orders/42?tab=2`). A shortcut answers `null` to it.

## Cold start and taps

- **A cold start** is answered in `launch()`. Every source is asked, in the order you listed them, and the first non-null answer wins. The answer is an `InboundLaunch` at the mapped location with `source: NavigationSource.shortcut` or `widget`, so the router is built there (over the platform's initial route) and the first navigation is marked. A sync source stays sync; a `Future` from one source is awaited, and it delays the first frame.
- **A warm action** is handled in `attach(router, container)`: the package subscribes to each source's `actions` with one `container.listen` per source, so the subscriptions go with the `ProviderScope`, and calls `router.go` or `router.push` inside `navigateFrom(NavigationSource.shortcut or .widget, ...)`. **The guards run**: a signed-out shortcut to a guarded page lands on the login page with `from`, as for any link.
- **A startup hold** (since 0.18.0). `launch()` runs before `runApp` and `attach` after `startup()`, `ready()` and the first frame of the router, and a source's `actions` is a broadcast stream, so an action in between would be lost. From `launch()` on, the package listens to every source in a container of its own and keeps the **latest** action across them (one, never a queue: the newest replaces the one before, with no timer). `attach` subscribes the scope first, ends the hold, and opens what it kept once, as a warm action, after the rest of the adapter is attached.
- **The cold-start action is not opened twice.** A cold-start action that the stream says again during startup is dropped once, by equality (a shortcut by its `type`, a widget by its `uri`). An equal action after `attach` is a new one and opens.
- **One subscription per scope.** A second router built on the same container is ignored, and the first router gets the actions.
- **On the web `launch()` is never asked**, and a shortcut or a widget opens the app as an ordinary URL.
- `fespalier.launch.routed` says the mapping gave a place and the navigation call was made; on a cold start another adapter's `launch()` may still have won.

Telemetry (the package's own names, `FespalierLaunchConventions`, since 0.18.0): `fespalier.launch.open` with `fespalier.launch.state` (`cold` or `warm`) and `fespalier.launch.kind` (`shortcut` or `widget`), and on its end `fespalier.launch.routed` (`bool`). The navigation it starts carries `fespalier.navigation.source`, `shortcut` or `widget`. A shortcut type, a widget URI, a path, a query, an id and any text the plugin gives are **never reported**: the names above are constants and a boolean, and `test/telemetry_test.dart` pins them.

## Widgets and platform links

With Flutter's deep linking on (the default in recent Flutter), a widget's URI can reach the router a second way: as a platform link, through the same binding that carries an App Link.

- **A launch wins on a cold start.** The launch sets `overridePlatformDefaultLocation` ([Opening the app](navigation.md#opening-the-app-launches-and-platform-links)), so the platform's initial route does not replace the location the launch mapped.
- **Whether the widget's URI also arrives as a link is UNCHECKED** (item 6 below). If it does, a warm tap may navigate twice to the same place, in an order this package cannot promise. So give the widget the in-app location as its path (`myapp:///orders/42`) and map it with `widgetLinkRoute`: both ways then agree on the place, and neither is the wrong one.

**What no test shows (UNCHECKED).** Everything below is a claim about a platform, and no CI job runs a launcher. Each is to be checked on a device before a release, and none is stated as fact by this package:

1. **quick_actions, Android cold start**: the shortcut reaches the handler inside `initialize()`, so it is the initial location (`state=cold`).
2. **quick_actions, iOS cold start**: the plugin sends it when the app becomes active. Either it is buffered before `initialize`, so it is cold, or it arrives later through the startup hold, so it is warm, after the first frame, with the home page shown briefly. This is unknown per iOS version and under UIScene.
3. **quick_actions warm taps**, on both platforms, arrive through the handler, so on `actions`.
4. **home_widget cold start**: `initiallyLaunchedFromHomeWidget()` answers before the first frame, on Android and on iOS.
5. **home_widget warm taps** arrive on `widgetClicked`. On Android it delivers through `onNewIntent` only while the EventChannel is listened to.
6. **The widget's URI as a platform link**: with Flutter deep linking on, it may also reach the router, as described above. On a warm tap that means two navigations (`link` and `widget`) to the same place, in an unknown order. On iOS a cold start may add a later `link` navigation.
7. **Hot restart**: home_widget answers the launch intent again, so the widget's target opens again. This is a development effect only.

## Testing

`package:fespalier_launch/testing.dart` has `FakeLaunchSource` (`initial:`, `initialReads`; `shortcut(type)`, `widget(uri)`, `act(action)`, `fail(error)`). A widget test boots the app as it runs, with `configure` called first, because `AppMain.root()` runs no `main()`:

```dart
final shortcuts = FakeLaunchSource(initial: const ShortcutAction('last_order'));
FespalierLaunch.configure(sources: [shortcuts], route: launchRoute);
final launch = await AppAdapters.launch(); // what main() does before runApp
await tester.pumpWidget(AppMain.root(router: () => AppRoutes.router(launch: launch)));
shortcuts.shortcut('account');
await tester.pumpAndSettle();
```

An action while the app starts is the same test with `shortcuts.shortcut(...)` between `AppAdapters.launch()` and `pumpWidget`: it opens once, after the first frame, and only the latest of several does. Call `FespalierLaunch.debugReset()` in `setUp` and `tearDown` (it also ends the hold that `launch()` started), and the same for `FespalierPush` if the app lists it.

[`examples/plugins`](../examples/plugins) tests a cold start from a shortcut and from a widget, a tap while the app runs and while it starts, a signed-out shortcut to a guarded page, a URI and a shortcut the app does not map, and the two home-page buttons, through `AppMain.root()`; no device is needed. Its `test/launch_test.dart` is the model. What no test can see is the list above: a real shortcut or widget tap, cold and warm, on each platform. Do it on a device before a release.
