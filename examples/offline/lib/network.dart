import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// What a call fails with while the switch is off: no answer came, as when a phone has no signal.
class Unreachable implements Exception {
  /// The switch is off.
  const Unreachable();

  @override
  String toString() => 'Unreachable';
}

/// The app bar's "Online" switch. It stands in for the device's network: a real app has
/// `connectivity_plus` (`fespalier_connectivity`'s `ConnectivitySignal`) fire `reconnectSignal` instead.
final networkOnline = NotifierProvider<NetworkSwitch, bool>(NetworkSwitch.new);

/// The state of [networkOnline].
class NetworkSwitch extends Notifier<bool> {
  @override
  bool build() => true;

  /// Turns the "network" on or off. Getting it back fires `reconnectSignal`, which `autoSync` and the
  /// orders' `refetchOnReconnect` both follow (and `fespalier_connectivity` fires on a real device).
  void set({required bool online}) {
    if (state == online) return;
    state = online;
    if (online) ref.read(reconnectSignal.notifier).fire();
  }
}

/// A transport that fails with [Unreachable] while the switch is off, and sends through otherwise.
final class SwitchedTransport implements CrateStackTransport {
  /// Sends through [_inner] while [_online] answers true.
  const SwitchedTransport(this._inner, this._online);

  final CrateStackTransport _inner;
  final bool Function() _online;

  @override
  Future<Object?> send(CrateStackCall call, {String? idempotencyKey}) {
    if (!_online()) throw const Unreachable();
    return _inner.send(call, idempotencyKey: idempotencyKey);
  }
}
