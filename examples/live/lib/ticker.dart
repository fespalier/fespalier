import 'dart:async';

import 'package:fespalier_stream/fespalier_stream.dart';

/// The app's tick for every live feed (fespalier_stream starts no timer of its own): every 15 seconds
/// it closes a connection whose page stayed hidden since the tick before, closes one whose server went
/// quiet for `LiveRules.idle`, and opens again one that dropped. The period is the app's backoff.
///
/// The timer runs while every page that watches a feed is hidden (it stops in `onDispose`, not in
/// `onCancel`): closing their connections is what it is for. The app bar's **Tick now** fires it by
/// hand, and tests replace it with `ManualStreamTicker`.
final class AppStreamTicker extends StreamTicker {
  /// How often it fires.
  static const period = Duration(seconds: 15);

  @override
  int build() {
    final timer = Timer.periodic(period, (_) => fire());
    ref.onDispose(timer.cancel);
    return super.build();
  }
}
