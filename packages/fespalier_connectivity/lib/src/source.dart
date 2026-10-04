import 'package:connectivity_plus/connectivity_plus.dart';

/// Where network changes come from (since 0.9.0): connectivity_plus by default, a fake in tests.
abstract interface class ConnectivitySource {
  /// Each change of the device's network interfaces; `[ConnectivityResult.none]` when there is none. May not send
  /// the current state on listen (the web does not).
  Stream<List<ConnectivityResult>> get changes;

  /// The state now.
  Future<List<ConnectivityResult>> check();
}

/// connectivity_plus' `Connectivity()` (a singleton: never create another listener of its own beside this one).
final class PluginConnectivitySource implements ConnectivitySource {
  /// The plugin's source.
  const PluginConnectivitySource();

  @override
  Stream<List<ConnectivityResult>> get changes =>
      Connectivity().onConnectivityChanged;

  @override
  Future<List<ConnectivityResult>> check() =>
      Connectivity().checkConnectivity();
}
