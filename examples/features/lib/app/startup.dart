import 'dart:async';

import 'package:features/auth.dart';
import 'package:fespalier/fespalier.dart'
    show dataCacheStorage, reconnectSignal;
import 'package:fespalier/startup.dart';
import 'package:fespalier_connectivity/fespalier_connectivity.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:fespalier_storage/fespalier_storage.dart';

/// What the app asked this file for, in order. The tests read it to check when each runs.
final List<String> startupLog = [];

/// Where the session is kept between runs. A real app reads shared preferences or a secure
/// store here; this one is a flag, and `restore()` is as async as a disk read.
class SessionStore {
  /// A store that remembers whether someone was [signedIn].
  const SessionStore({this.signedIn = false});

  /// What `restore()` answers.
  final bool signedIn;

  /// Reads the saved session.
  Future<bool> restore() async => signedIn;
}

/// The store `startup()` reads. A test swaps it for one that is signed in, or that fails.
SessionStore sessionStore = const SessionStore();

const _inZone = #featuresStartupZone;

/// Wraps all of main(): the binding, startup() and `runApp` run inside `body`. A real app
/// puts its crash reporter's zone here (`runZonedGuarded`, a telemetry SDK). It has to work on
/// the web too.
Future<void> zone(Future<void> Function() body) {
  startupLog.add('zone');
  return runZoned(body, zoneValues: {_inZone: true});
}

/// Runs once before the app, while splash.dart shows. The providers it returns are overridden
/// in the app's `ProviderScope`, so the first frame of the app already knows the session.
Future<List<Override>> startup() async {
  startupLog.add(Zone.current[_inZone] == true ? 'startup in zone' : 'startup');
  final signedIn = await sessionStore.restore();
  return [
    session.overrideWith(() => _Restored(signedIn)),
    // --dart-define=FEATURES_LABS=true shows /labs (fespalier_flags).
    flagSource.overrideWithValue(
      const ConstFlags({'labs': bool.fromEnvironment('FEATURES_LABS')}),
    ),
    // fespalier_storage: the team's dataCache in shared preferences (null if they could not open: nothing saved).
    dataCacheStorage.overrideWithValue(await PrefsDataStorage.open()),
    // fespalier_connectivity: refetchOnReconnect (teams/$teamId/route.dart) follows connectivity_plus.
    reconnectSignal.overrideWith(ConnectivitySignal.new),
  ];
}

class _Restored extends Flag {
  _Restored(this.value);

  final bool value;

  @override
  bool build() => value;
}

/// The `ProviderScope`'s observers, read after startup().
List<ProviderObserver> get providerObservers {
  startupLog.add('providerObservers');
  return [];
}

/// The `ProviderScope`'s retry policy: a failing provider is not retried.
Duration? retry(int retryCount, Object error) => null;
