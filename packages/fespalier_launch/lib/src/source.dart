import 'dart:async';

import 'action.dart';

/// What a launch provider gives fespalier_launch (since 0.18.0): the shortcut and widget plugins
/// of the app, each wrapped in one of these. One or more per app, handed over with
/// `FespalierLaunch.configure(sources:)`; `package:fespalier_launch/testing.dart` has
/// `FakeLaunchSource`. The vendor plugins (quick_actions, home_widget) are recipes in the
/// fespalier-routing skill, not dependencies of this package.
///
/// Implementations keep the rules of an adapter: nothing here may start a timer, and the read
/// that runs before the first frame ([initialAction]) is a local one, never the network.
abstract class LaunchSource {
  /// Constant, so a source with no state is `const`.
  const LaunchSource();

  /// The action that cold-started the app, answered once (a second call answers null). It is a
  /// local read: it runs before the first frame, so a `Future` delays that frame by one channel
  /// round trip. Every source is asked, in the order the app listed them.
  FutureOr<LaunchAction?> initialAction();

  /// The actions taken while the app runs or sits in the background. Listened to once per
  /// `ProviderScope`, and (since 0.18.0) once more from `launch()` until the scope's own
  /// subscription exists: the adapter keeps the latest action that arrives while the app starts
  /// (one, not a queue) and opens it after the first frame. Make it a broadcast stream, and when
  /// it is built on a platform channel, return the same stream every time (a `late final` field):
  /// two `receiveBroadcastStream()` of one channel replace each other's handler, and a cancel
  /// silences both.
  Stream<LaunchAction> get actions;
}
