import 'package:offline/app.main.g.dart';

// lib/app/app.dart and startup.dart are the app; AppMain (lib/app.main.g.dart) is generated from them.
// startup() wires fespalier_cratestack to the in-process demo server, so `flutter run` needs no backend.
Future<void> main() => AppMain.run();
