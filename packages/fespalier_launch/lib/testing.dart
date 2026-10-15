/// Fakes for a widget test of an app that uses fespalier_launch (since 0.18.0). No plugin, no
/// channel and no timer: a test starts a shortcut or a widget tap by hand.
///
/// ```dart
/// final shortcuts = FakeLaunchSource(initial: const ShortcutAction('last_order'));
/// FespalierLaunch.configure(sources: [shortcuts], route: launchRoute);
/// await tester.pumpWidget(AppMain.root());
/// shortcuts.shortcut('account');
/// ```
library;

import 'dart:async';

import 'fespalier_launch.dart';

/// A [LaunchSource] driven by hand.
class FakeLaunchSource extends LaunchSource {
  /// A source whose [initialAction] answers [initial] once.
  FakeLaunchSource({LaunchAction? initial}) : _initial = initial;

  LaunchAction? _initial;
  final _actions = StreamController<LaunchAction>.broadcast();

  /// How many times [initialAction] was called: the package asks each source once per launch.
  int initialReads = 0;

  @override
  LaunchAction? initialAction() {
    initialReads++;
    final action = _initial;
    _initial = null;
    return action;
  }

  @override
  Stream<LaunchAction> get actions => _actions.stream;

  /// An action taken while the app runs (or sits in the background).
  void act(LaunchAction action) => _actions.add(action);

  /// A home-screen shortcut of [type] was chosen.
  void shortcut(String type) => act(ShortcutAction(type));

  /// A home-screen widget was tapped; the widget opened the app at [uri].
  void widget(Uri uri) => act(WidgetAction(uri));

  /// The actions stream fails (a plugin error).
  void fail(Object error) => _actions.addError(error);

  /// Closes the stream.
  Future<void> close() => _actions.close();
}
