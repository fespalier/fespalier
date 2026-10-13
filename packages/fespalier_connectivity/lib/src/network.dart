import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, listEquals;

import 'source.dart';

/// Where [networkConnectivity] listens (since 0.9.0). Override it in tests with a `FakeConnectivity`: without one,
/// a widget test that shows [hasNetwork] reaches the plugin and fails (C3).
final connectivitySource = Provider<ConnectivitySource>(
  (ref) => const PluginConnectivitySource(),
);

/// The device's network interfaces as connectivity_plus reports them (since 0.9.0); null until the first answer.
/// One subscription while something watches it; asked again when the app resumes.
final networkConnectivity =
    NotifierProvider.autoDispose<
      NetworkConnectivity,
      List<ConnectivityResult>?
    >(NetworkConnectivity.new);

/// What [networkConnectivity] holds (since 0.9.0).
///
/// It listens to [ConnectivitySource.changes], asks [ConnectivitySource.check] once for the state now (the web sends
/// nothing on listen, and any platform may not) and again on each resume (iOS drops events while the app is in the
/// background). An event that arrives before the first answer wins over it. It starts no timer.
class NetworkConnectivity extends Notifier<List<ConnectivityResult>?> {
  @override
  List<ConnectivityResult>? build() {
    final source = ref.watch(connectivitySource);
    var heard = false;
    try {
      final subscription = source.changes.listen(
        (results) {
          heard = true;
          _set(results);
        },
        onError: (Object error, StackTrace _) =>
            _print('the connectivity stream reported an error', error), // C1
      );
      ref.onDispose(subscription.cancel);
    } on Object catch (error) {
      _print('the connectivity stream reported an error', error); // C1
    }
    _check(source, accept: () => !heard && ref.mounted);
    // iOS drops connectivity events while the app is in the background: ask again on each resume. The signal needs a
    // WidgetsBinding, which a bare ProviderContainer in a test does not have: that is not an error here.
    ref.listen(
      appResumeSignal,
      (_, _) => _check(source, accept: () => ref.mounted),
      onError: (_, _) {},
    );
    return null;
  }

  /// Asks [source] for the state now, and applies the answer when [accept] says it still counts (a later event wins
  /// over a late answer). A failure is printed (C2) and changes nothing.
  void _check(ConnectivitySource source, {required bool Function() accept}) {
    final Future<List<ConnectivityResult>> answer;
    try {
      answer = source.check();
    } on Object catch (error) {
      _print('checking connectivity failed', error); // C2
      return;
    }
    answer.then<void>(
      (results) {
        if (accept()) _set(results);
      },
      onError: (Object error, StackTrace _) =>
          _print('checking connectivity failed', error), // C2
    );
  }

  void _set(List<ConnectivityResult> results) {
    if (!listEquals(state, results)) state = List.unmodifiable(results);
  }
}

void _print(String what, Object error) {
  if (kDebugMode) debugPrint('fespalier_connectivity: $what: $error');
}

/// Whether a network interface is up (since 0.9.0): false only once the device has said `[none]`; true before the
/// first answer, so nothing flashes "offline" at start. Not whether the internet answers (docs/data.md, "Reconnects: fespalier_connectivity").
final hasNetwork = Provider.autoDispose<bool>(
  (ref) =>
      !(ref.watch(networkConnectivity)?.contains(ConnectivityResult.none) ??
          false),
);
