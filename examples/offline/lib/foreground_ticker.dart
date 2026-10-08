import 'dart:async';

import 'package:fespalier/fespalier.dart';

/// The app's own periodic trigger for `autoSync`. fespalier_cratestack starts no timer, so the tick is a
/// signal the app fires: this one every five minutes while the root layout shows (autoDispose, watched
/// only by `autoSync`). Tests replace it with `ManualSyncTicker`.
class ForegroundTicker extends RefetchSignal {
  @override
  int build() {
    final timer = Timer.periodic(const Duration(minutes: 5), (_) => fire());
    ref.onDispose(timer.cancel);
    return 0;
  }
}
