import 'package:fespalier/fespalier.dart' show reconnectSignal;
import 'package:fespalier/startup.dart';
import 'package:fespalier_connectivity/fespalier_connectivity.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:live/ticker.dart';
import 'package:live/wiring.dart';

/// Runs once before the app: the server the feeds talk to, and the two things that open a feed that
/// dropped, since fespalier_stream waits on nothing of its own.
///
/// - `liveWiring()` points the app at `--dart-define=LIVE_ORIGIN=...` (tool/server.dart), or at the
///   in-process demo server when it is not given.
/// - The tick is the app's own timer ([AppStreamTicker], every 15 s).
/// - `reconnectSignal` fires when the device gets a network back (fespalier_connectivity), so a feed that
///   dropped opens again at once; `appShowSignal` (the app is visible again) needs no override.
List<Override> startup() => [
  ...liveWiring(),
  streamTicker.overrideWith(AppStreamTicker.new),
  reconnectSignal.overrideWith(ConnectivitySignal.new),
];
