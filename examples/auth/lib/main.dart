import 'package:auth/app.main.g.dart';

// The generated main() (lib/app.main.g.dart) runs lib/app/startup.dart first: it reads the stored
// session with restoreAuth, and splash.dart shows meanwhile. The guards are synchronous from the
// first navigation, so a deep link to a signed-in page has no blank frame and no redirect.
Future<void> main() => AppMain.run();
