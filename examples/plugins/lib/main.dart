import 'package:fespalier_push/fespalier_push.dart';
import 'package:plugins/app.main.g.dart';
import 'package:plugins/push.dart';

// A package that needs the app's own code is configured before the adapters run, which is
// AppMain.run(): the pubspec carries no per-adapter options (docs/adapters.md, "Adapters that
// need your code"). No telemetry sink is installed here, so nothing is reported; the tests
// install a recording one.
Future<void> main() {
  FespalierPush.configure(
    source: demoPush,
    route: pushRoute,
    onToken: sendToken,
  );
  return AppMain.run();
}
