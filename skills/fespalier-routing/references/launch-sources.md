# Launch sources: quick_actions (shortcuts) and home_widget (widgets)

Since 0.18.0. A [`LaunchSource`](launch.md) is `initialAction()` and `actions`, so a bridge to a launcher plugin is a few lines of mapping with nothing of fespalier left in it. That is why each plugin is a **recipe on this page, not a package**: `fespalier_launch` would otherwise link both plugins into every app that lists it, and an app that uses only shortcuts would carry the widget plugin's native side. **Promote a recipe to a package** only when apps ask for a turnkey one.

The samples are built by `just skill-samples` (`fsp gen`, `flutter analyze`, and `flutter test` for the one test below, which is of the URL rule and never runs a plugin). Built on 2026-10-15 against `quick_actions` 1.1.1 and `home_widget` 0.10.0; no device has run them and the native side (the shortcut icons, the widget's own XML or SwiftUI, the App Group) is never built.

**The floors are the app's, not fespalier's.** `quick_actions` 1.1.1 needs Flutter 3.38 and `home_widget` 0.10.0 needs Flutter 3.38.1. On Flutter 3.35 (fespalier's floor) use `quick_actions` 1.1.0 (Flutter 3.19) and `home_widget` 0.9.2+1 (Flutter 3.20): the calls the recipes make are the same in all four.

```yaml
# pubspec.yaml dependencies
  quick_actions: ^1.1.1
  home_widget: ^0.10.0
```

## The rules every source follows

- **`initialAction()` is a local read, answered once, and it must complete or fail.** It runs before the first frame, and `launch()` runs inside the adapters' zones, so a source that initialises its plugin does it in the first call that needs it, never in `main()` before `AppMain.run()`. The first frame waits for the answer and the package sets no timeout, so a `Future` that never completes blocks the app for good: the plugin calls below are platform-channel calls that answer.
- **Build each source once** and use that one object everywhere: a top-level `final` (`quickActions`, `homeWidget` below) that `configure` and `startup()` both read. A second `QuickActionsLaunchSource()` calls `initialize` again, and quick_actions keeps a single handler, so the source you configured would stop hearing warm shortcuts.
- **Only Android and iOS.** quick_actions has no other implementation and home_widget only an Android and an iOS side, so on the web and the desktop a call throws `MissingPluginException`. Each source checks the platform itself: off Android and iOS it answers no launch action, has no actions and does nothing.
- **`actions` is the same broadcast stream every time** (a `late final` field, or a controller's `stream`). Two `receiveBroadcastStream()` of one platform channel replace each other's handler, and `home_widget`'s `widgetClicked` makes a new one on every read, so the source reads it once.
- **The plugin's own object is `raw`, for your `LaunchRoute` only.** The package never reads it, and `raw` is not part of equality.
- **Only what the plugin says is an action.** A shortcut is its `type`, a widget is its `uri`. The package keys nothing else.
- **No timer.** A source does not poll; the plugins call back.

## quick_actions: shortcuts

`initialize(handler)` is the plugin's one entry point. The design assumes that the handler is called inside `initialize()` on Android, so a shortcut that opened the app arrives before the future completes, and when the app becomes active on iOS (both UNCHECKED on a device). The source keeps the first shortcut that arrives before `initialize()` completes as the launch, and sends every later one to its stream. `setShortcutItems` must follow `initialize()`, so the source waits for it.

The app has **one** `quickActions`. `configure` is given that object and `startup()` calls `setShortcuts()` on it (below): `QuickActionsLaunchSource().setShortcuts()` would make a second source, whose `initialize` replaces the plugin's one handler and silences the first.

```dart
// lib/launch/quick_actions_source.dart
import 'dart:async';

import 'package:fespalier_launch/fespalier_launch.dart';
import 'package:flutter/foundation.dart';
import 'package:quick_actions/quick_actions.dart';

/// The app's one shortcut source: hand this object to FespalierLaunch.configure and call
/// setShortcuts() on it from startup(). Never build a second QuickActionsLaunchSource: its
/// initialize() would replace the plugin's single handler.
final quickActions = QuickActionsLaunchSource();

/// Home-screen shortcuts through quick_actions (since 0.18.0).
final class QuickActionsLaunchSource extends LaunchSource {
  static const _plugin = QuickActions();

  // quick_actions has an Android and an iOS side only: anywhere else a call throws
  // MissingPluginException.
  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

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
    if (!_supported) return null;
    await _ready;
    if (_asked) return null;
    _asked = true;
    final type = _launch;
    return type == null ? null : ShortcutAction(type);
  }

  @override
  Stream<LaunchAction> get actions => _controller.stream;

  /// The shortcuts the launcher shows. Call it from startup(), which runs after launch(): this
  /// waits for initialize() as well, so it is safe to call before the first frame. It does
  /// nothing off Android and iOS.
  Future<void> setShortcuts() async {
    if (!_supported) return;
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

**On iOS the widget's URL needs a marker.** home_widget reports a URL on iOS only when it carries a `homeWidget` query item (`isWidgetUrl` in the plugin's `HomeWidgetPlugin.swift`, read at 0.10.0 and at 0.9.2+1). The widget's SwiftUI view sets it with `.widgetURL(URL(string: "myapp:///orders/42?homeWidget"))` (a `Link` takes the same URL); `myapp:///orders/42` alone never reaches `initiallyLaunchedFromHomeWidget()` or `widgetClicked` on iOS. The marker belongs to the plugin, not to your route, so the source drops it before it builds the `WidgetAction`, and `widgetLinkRoute` yields `/orders/42`, not `/orders/42?homeWidget`. Android needs no marker (the plugin reports the data of an intent made with `HomeWidgetLaunchIntent`), and dropping one that is not there changes nothing.

```dart
// lib/launch/home_widget_source.dart
import 'package:fespalier_launch/fespalier_launch.dart';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

/// The app's one widget source: hand this object to FespalierLaunch.configure.
final homeWidget = HomeWidgetLaunchSource();

/// [uri] without the `homeWidget` query item that iOS needs to report a widget's URL (see
/// home_widget's isWidgetUrl). Every other item stays as it was written, and a URL with no marker
/// is returned as it is.
Uri withoutHomeWidgetMarker(Uri uri) {
  if (!uri.hasQuery) return uri;
  final items = uri.query.split('&');
  final kept = [
    for (final item in items)
      if (item != 'homeWidget' && !item.startsWith('homeWidget=')) item,
  ];
  if (kept.length == items.length) return uri;
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.hasAuthority ? uri.host : null,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    query: kept.isEmpty ? null : kept.join('&'),
    fragment: uri.hasFragment ? uri.fragment : null,
  );
}

/// Home-screen widget taps through home_widget (since 0.18.0).
final class HomeWidgetLaunchSource extends LaunchSource {
  bool _asked = false;

  // home_widget has an Android and an iOS side only: anywhere else a call throws
  // MissingPluginException, and so does listening to widgetClicked.
  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  // One stream, the same every time: widgetClicked makes a new platform stream on each read.
  late final Stream<LaunchAction> _actions = HomeWidget.widgetClicked
      .where((uri) => uri != null)
      .map<LaunchAction>((uri) => WidgetAction(withoutHomeWidgetMarker(uri!)));

  @override
  Future<LaunchAction?> initialAction() async {
    if (!_supported || _asked) return null;
    _asked = true;
    final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    return uri == null ? null : WidgetAction(withoutHomeWidgetMarker(uri));
  }

  @override
  Stream<LaunchAction> get actions =>
      _supported ? _actions : const Stream<LaunchAction>.empty();
}
```

The launch and the stream both drop the marker, so the cold-start action that the stream says again during startup is still the same action by `uri`. The rule is tested without a plugin:

```dart
// test/home_widget_source_test.dart
import 'package:fespalier_launch/fespalier_launch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/launch/home_widget_source.dart';

void main() {
  String strip(String url) => withoutHomeWidgetMarker(Uri.parse(url)).toString();

  test('the marker is dropped and every other item is kept as written', () {
    expect(strip('myapp:///orders/42?homeWidget'), 'myapp:///orders/42');
    expect(strip('myapp:///orders/42?homeWidget=1'), 'myapp:///orders/42');
    expect(strip('myapp:///orders/42?tab=2&homeWidget'), 'myapp:///orders/42?tab=2');
    expect(strip('myapp:///orders/42?homeWidget&tab=a%20b#x'), 'myapp:///orders/42?tab=a%20b#x');
  });

  test('a URL without the marker is returned as it is', () {
    final plain = Uri.parse('myapp:///orders/42?tab=2');
    expect(identical(withoutHomeWidgetMarker(plain), plain), isTrue);
    expect(strip('myapp:///orders/42'), 'myapp:///orders/42');
    expect(strip('myapp:///a?homeWidgetId=3'), 'myapp:///a?homeWidgetId=3');
    expect(withoutHomeWidgetMarker(Uri()), Uri());
  });

  test('widgetLinkRoute then opens the path, not the marker', () {
    final route = widgetLinkRoute(schemes: {'myapp'}, matches: (_) => true);
    String? at(String url) =>
        route(WidgetAction(withoutHomeWidgetMarker(Uri.parse(url))))?.location;
    expect(at('myapp:///orders/42?homeWidget'), '/orders/42');
    expect(at('myapp:///orders/42?tab=2&homeWidget'), '/orders/42?tab=2');
    expect(at('myapp:///orders/42'), '/orders/42');
  });
}
```

- **Android and iOS cold start, UNCHECKED**: `initiallyLaunchedFromHomeWidget()` is expected to answer before the first frame.
- **Warm taps, UNCHECKED**: they are expected on `widgetClicked`. The source listens to it from `launch()` on, because the plugin may deliver a tap on Android only while its EventChannel is listened to.
- **iOS sends the URL a second time, UNCHECKED**: the plugin also takes it from `application(_:open:)`, so after a cold start or a warm tap it may arrive on `widgetClicked` once more after `attach`, as a second warm navigation to the same place.

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
    sources: [quickActions, homeWidget],
    route: launchRoute,
  );
}
```

`main()` calls `configureLaunch()` before `AppMain.run()`, and `startup()` (which runs after `launch()`) calls `setShortcuts()` on **the same** `quickActions`:

```dart
// lib/main.dart
import 'app.main.g.dart';
import 'launch/route.dart';

Future<void> main() {
  configureLaunch();
  return AppMain.run();
}
```

```dart
// lib/app/startup.dart
import '../launch/quick_actions_source.dart';

/// Sets the shortcuts the launcher shows. launch() has run by now, and this is the quickActions
/// that configureLaunch() handed to the package.
Future<void> startup() => quickActions.setShortcuts();
```

```yaml
# pubspec.yaml
fespalier:
  adapters: [fespalier_launch]
```

With `fespalier: adapters: [fespalier_launch]` listed, that is the whole wiring.

## Not on the web

On the web `launch()` is never asked, and a shortcut or a widget opens the app as an ordinary URL. `attach` still listens to every source's `actions`, so a source over a platform channel that has no web side can fail when it is listened to, and where the failure shows depends on the plugin. A stream that emits an error is reported by fespalier_launch (`in the stream of launch actions`). A platform channel that fails to activate is not: for home_widget, `widgetClicked` activates `home_widget/updates` when it is first listened to, and **Flutter's services library** reports the error (`while activating platform stream on channel home_widget/updates`), not fespalier_launch. The sources above avoid both off Android and iOS: `initialAction()` answers null, `actions` is an empty stream and `setShortcuts()` does nothing. A source for a plugin that does have a web side gives the web that side instead.
