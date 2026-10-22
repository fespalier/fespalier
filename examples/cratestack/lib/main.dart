import 'package:cratestack_example/app.main.g.dart';

// The generated main() (lib/app.main.g.dart) runs lib/app/startup.dart first: it builds the app's one
// transport, restores the session (the stored attestation, and a check that the device key is the one
// it is bound to) and wires the generated client, with splash.dart showing meanwhile.
Future<void> main() => AppMain.run();
