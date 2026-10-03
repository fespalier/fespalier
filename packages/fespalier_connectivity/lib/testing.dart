/// What tests use from fespalier_connectivity (since 0.9.0).
library;

import 'dart:async';

import 'package:fespalier_connectivity/fespalier_connectivity.dart';

export 'package:fespalier_connectivity/fespalier_connectivity.dart'
    show ConnectivityResult, ConnectivitySource;

/// A ConnectivitySource for tests (since 0.9.0): `connectivitySource.overrideWithValue(fake)`; [set] delivers a change
/// synchronously, [check] answers [now]. It sends nothing on listen, like the web.
final class FakeConnectivity implements ConnectivitySource {
  /// A device whose state is [now] (Wi-Fi by default).
  FakeConnectivity({this.now = const [ConnectivityResult.wifi]});

  /// The state [check] answers; [set] changes it.
  List<ConnectivityResult> now;

  final _changes = StreamController<List<ConnectivityResult>>.broadcast(
    sync: true,
  );
  var _listeners = 0;
  var _checks = 0;

  /// Changes [now] and sends it.
  void set(List<ConnectivityResult> results) {
    now = results;
    _changes.add(results);
  }

  /// `set([ConnectivityResult.none])`.
  void offline() => set(const [ConnectivityResult.none]);

  /// `set([via])`.
  void online([ConnectivityResult via = ConnectivityResult.wifi]) => set([via]);

  /// How many listen to [changes] now.
  int get listenerCount => _listeners;

  /// How many times [check] ran.
  int get checks => _checks;

  /// A broadcast stream: [set] delivers to every listener before it returns. Nothing is sent when one starts listening.
  @override
  Stream<List<ConnectivityResult>> get changes =>
      Stream<List<ConnectivityResult>>.multi((listener) {
        _listeners++;
        final subscription = _changes.stream.listen(listener.addSync);
        listener.onCancel = () {
          _listeners--;
          return subscription.cancel();
        };
      }, isBroadcast: true);

  @override
  Future<List<ConnectivityResult>> check() {
    _checks++;
    return Future.value(now);
  }
}
