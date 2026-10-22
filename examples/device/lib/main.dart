import 'package:device/app.main.g.dart';

// The generated main() (lib/app.main.g.dart) runs lib/app/startup.dart first: it builds the app's one
// transport and restores the session (the stored attestation, and a check that the device key is
// the one it is bound to), with splash.dart showing meanwhile.
Future<void> main() => AppMain.run();
