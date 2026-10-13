import 'package:fespalier/startup.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:offline/foreground_ticker.dart';
import 'package:offline/wiring.dart';

/// Runs once before the app: the overrides that connect fespalier_cratestack to this app.
///
/// `appWiring()` is the transport (the in-process demo server, behind the app bar's switch), the error
/// reader and the account; `noteRowSync()` is the `RowSync` that moves the notes. The tick is the app's own timer. What a device build adds:
/// `localStore.overrideWithValue(await HiveLocalStore.open(directory: ...))` so a queued intent survives
/// the app exiting, and `reconnectSignal.overrideWith(ConnectivitySignal.new)` from `fespalier_connectivity`
/// (here the switch fires it).
List<Override> startup() => [
  ...appWiring(),
  noteRowSync(),
  syncTicker.overrideWith(ForegroundTicker.new),
];
