import 'package:live/app.main.g.dart';

// lib/app/app.dart and startup.dart are the app; AppMain (lib/app.main.g.dart) is generated from them.
// startup() points the feeds at the in-process demo server, or at LIVE_ORIGIN (lib/wiring.dart).
Future<void> main() => AppMain.run();
