# fespalier_launch

Shortcut and home-screen widget taps for [fespalier](https://github.com/fespalier/fespalier) (since 0.18.0): a cold start and a tap while the app runs open typed routes, marked `source=shortcut` or `source=widget`. It is an adapter (`fespalier: adapters: [fespalier_launch]`). The plugins are not dependencies: you give it a `LaunchSource` for each, and quick_actions and home_widget are recipes in the `fespalier-routing` skill. It starts no timer, sets no shortcut and no widget data, and its one listener is the adapter's `container.listen`.

The docs cover all of it: [Shortcuts and home-screen widgets](https://github.com/fespalier/fespalier/blob/main/docs/launch.md). This page is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are
the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.18.0
  fespalier_launch:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_launch
      ref: v0.18.0
```

<!-- x-release-please-end -->

## Wire it

```yaml
# pubspec.yaml
fespalier:
  adapters: [fespalier_launch]
```

```dart
// lib/main.dart: configure before the adapters run
Future<void> main() {
  // the app's one source of each kind (the recipes in the fespalier-routing skill build them once)
  FespalierLaunch.configure(sources: [quickActions, homeWidget], route: launchRoute);
  return AppMain.run();
}

// what an action goes to: a shortcut's type, or a widget's URI
final _widgetRoute = widgetLinkRoute(schemes: {'myapp'}, matches: (uri) => AppRoutes.matchUrl(uri) != null);

LaunchTarget? launchRoute(LaunchAction action) => switch (action) {
  ShortcutAction(type: 'last_order') => LaunchTarget.to(const OrderRoute(id: 42)),
  ShortcutAction() => null,
  WidgetAction() => _widgetRoute(action),
};
```

## Test it

```dart
final shortcuts = FakeLaunchSource(initial: const ShortcutAction('last_order'));
FespalierLaunch.configure(sources: [shortcuts], route: launchRoute);
shortcuts.shortcut('account');
```

`examples/plugins` shows it end to end.
