import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fespalier/fespalier.dart';

import 'network.dart';

/// fespalier's `reconnectSignal`, fired when the device goes from no network to a network (since 0.9.0):
/// `reconnectSignal.overrideWith(ConnectivitySignal.new)` in startup().
///
/// Not on the first answer, not on a Wi-Fi to mobile switch. It exists while a data.dart with `refetchOnReconnect`
/// is alive, and so does its connectivity subscription: an app with none pays nothing.
class ConnectivitySignal extends RefetchSignal {
  @override
  int build() {
    ref.listen(networkConnectivity, (previous, next) {
      final was =
          previous != null && previous.contains(ConnectivityResult.none);
      final now = next != null && !next.contains(ConnectivityResult.none);
      if (was && now) fire();
    });
    return 0;
  }
}
