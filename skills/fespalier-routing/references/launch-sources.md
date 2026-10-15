# Launch sources: quick_actions (shortcuts) and home_widget (widgets)

Since 0.18.0. A [`LaunchSource`](launch.md) is `initialAction()` and `actions`, so a bridge to a launcher plugin is a few lines of mapping with nothing of fespalier left in it. That is why each plugin is a **recipe on this page, not a package**: `fespalier_launch` would otherwise link both plugins into every app that lists it, and an app that uses only shortcuts would carry the widget plugin's native side. **Promote a recipe to a package** only when apps ask for a turnkey one.

The samples are built by `just skill-samples` (`fsp gen`, `flutter analyze`): none of them runs a plugin at test time. Built on 2026-10-15 against `quick_actions` 1.1.1 and `home_widget` 0.10.0; analyze only, so no device has run them and the native side (the shortcut icons, the widget's own XML or SwiftUI, the App Group) is never built.

**The floors are the app's, not fespalier's.** `quick_actions` 1.1.1 needs Flutter 3.38 and `home_widget` 0.10.0 needs Flutter 3.38.1. On Flutter 3.35 (fespalier's floor) use `quick_actions` 1.1.0 (Flutter 3.19) and `home_widget` 0.9.2+1 (Flutter 3.20): the calls the recipes make are the same in all four.

```yaml
# pubspec.yaml dependencies
  quick_actions: ^1.1.1
  home_widget: ^0.10.0
```

## The rules every source follows

- **`initialAction()` is a local read, answered once.** It runs before the first frame, and `launch()` runs inside the adapters' zones, so a source that initialises its plugin does it in the first call that needs it, never in `main()` before `AppMain.run()`.
- **`actions` is the same broadcast stream every time** (a `late final` field, or a controller's `stream`). Two `receiveBroadcastStream()` of one platform channel replace each other's handler, and `home_widget`'s `widgetClicked` makes a new one on every read, so the source reads it once.
- **The plugin's own object is `raw`, for your `LaunchRoute` only.** The package never reads it, and `raw` is not part of equality.
- **Only what the plugin says is an action.** A shortcut is its `type`, a widget is its `uri`. The package keys nothing else.
- **No timer.** A source does not poll; the plugins call back.

## quick_actions: shortcuts

`initialize(handler)` is the plugin's one entry point. The design assumes that the handler is called inside `initialize()` on Android, so a shortcut that opened the app arrives before the future completes, and when the app becomes active on iOS (both UNCHECKED on a device). The source keeps the first shortcut that arrives before `initialize()` completes as the launch, and sends every later one to its stream. `setShortcutItems` must follow `initialize()`, so the source waits for it.

```dart
// lib/launch/quick_actions_source.dart
import 'dart:async';

import 'package:fespalier_launch/fespalier_launch.dart';
import 'package:quick_actions/quick_actions.dart';

/// Home-screen shortcuts through quick_actions (since 0.18.0).
final class QuickActionsLaunchSource extends LaunchSource {
  static const _plugin = QuickActions();

  final _controller = StreamController<LaunchAction>.broadcast();
  String? _launch;
  bool _started = false;
  bool _asked = false;

  // Before initialize() completes, the first shortcut is the one that opened the app.
  void _handle(String type) {
    if (!_started && _launch == null) {
      _launch = type;
      return;
    }
    _controller.add(ShortcutAction(type));
  }

  void _markStarted() => _started = true;

  late final Future<void> _ready = _plugin
      .initialize(_handle)
      .whenComplete(_markStarted);

  @override
  Future<LaunchAction?> initialAction() async {
    await _ready;
    if (_asked) return null;
    _asked = true;
    final type = _launch;
    return type == null ? null : ShortcutAction(type);
  }

  @override
  Stream<LaunchAction> get actions => _controller.stream;

  /// The shortcuts the launcher shows. Call it from startup(), which runs after launch(): this
  /// waits for initialize() as well, so it is safe to call before the first frame.
  Future<void> setShortcuts() async {
    await _ready;
    await _plugin.setShortcutItems(const [
      ShortcutItem(
        type: 'new_order',
        localizedTitle: 'New order',
        icon: 'ic_new_order',
      ),
    ]);
  }
}
```

- **Android cold start, UNCHECKED**: expected to reach the handler inside `initialize()`, so the source's launch is the initial location. See [the UNCHECKED list](launch.md#behaviour-to-rely-on-and-traps).
- **iOS cold start, UNCHECKED**: whether the plugin buffers it before `initialize()` (cold) or sends it later (warm, through the startup hold, after the first frame) is unknown per iOS version and under UIScene.

## home_widget: widget taps

`HomeWidget.initiallyLaunchedFromHomeWidget()` answers the launch intent, and the plugin answers the same intent on every call, so the source asks once. `HomeWidget.widgetClicked` is the tap while the app runs. Its value is `null` for an empty event and an empty `Uri()` for a value that does not parse; `widgetLinkRoute` refuses an empty URI, so the second is refused and never opened.

```dart
// lib/launch/home_widget_source.dart
import 'package:fespalier_launch/fespalier_launch.dart';
import 'package:home_widget/home_widget.dart';

/// Home-screen widget taps through home_widget (since 0.18.0).
final class HomeWidgetLaunchSource extends LaunchSource {
  bool _asked = false;

  // One stream, the same every time: widgetClicked makes a new platform stream on each read.
  late final Stream<LaunchAction> _actions = HomeWidget.widgetClicked
      .where((uri) => uri != null)
      .map<LaunchAction>((uri) => WidgetAction(uri!));

  @override
  Future<LaunchAction?> initialAction() async {
    if (_asked) return null;
    _asked = true;
    final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    return uri == null ? null : WidgetAction(uri);
  }

  @override
  Stream<LaunchAction> get actions => _actions;
}
```

- **Android and iOS cold start, UNCHECKED**: `initiallyLaunchedFromHomeWidget()` is expected to answer before the first frame.
- **Warm taps, UNCHECKED**: they are expected on `widgetClicked`. The source listens to it from `launch()` on, because the plugin may deliver a tap on Android only while its EventChannel is listened to.

## The mapping and the configuration

```dart
// lib/launch/route.dart
import 'package:fespalier_launch/fespalier_launch.dart';

import '../app.g.dart';
import 'home_widget_source.dart';
import 'quick_actions_source.dart';

/// A widget opens the app at a URI whose path is the in-app location: `myapp:///orders/42`.
final LaunchRoute _widgetRoute = widgetLinkRoute(
  schemes: {'myapp'},
  hosts: {'shop.example.com'},
  matches: (uri) => AppRoutes.matchUrl(uri) != null,
);

/// A shortcut's type is matched by a switch on your own constants, never by what it carries.
LaunchTarget? launchRoute(LaunchAction action) => switch (action) {
  ShortcutAction(type: 'home') => LaunchTarget.to(const HomeRoute()),
  ShortcutAction() => null,
  WidgetAction() => _widgetRoute(action),
};

/// Configures the launch sources and the mapping. main() calls it before AppMain.run().
void configureLaunch() {
  FespalierLaunch.configure(
    sources: [QuickActionsLaunchSource(), HomeWidgetLaunchSource()],
    route: launchRoute,
  );
}
```

`main()` calls `configureLaunch()` before `AppMain.run()`, and calls the source's `setShortcuts()` from `startup()` (which runs after `launch()`). With `fespalier: adapters: [fespalier_launch]` listed, that is the whole wiring.

## Not on the web

On the web `launch()` is never asked, and a shortcut or a widget opens the app as an ordinary URL. `attach` still listens to `actions`, so a plugin with no web side may report an error there, once, through `FlutterError` (in the stream of launch actions). A source for such a plugin gives the web an empty `actions` instead: a conditional import of a stub, not built here.
