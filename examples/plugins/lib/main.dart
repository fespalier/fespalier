import 'package:fespalier_analytics/fespalier_analytics.dart';
import 'package:fespalier_push/fespalier_push.dart';
import 'package:plugins/analytics.dart';
import 'package:plugins/app.main.g.dart';
import 'package:plugins/push.dart';

// A package that needs the app's own code is configured before the adapters run, which is
// AppMain.run(): the pubspec carries no per-adapter options (docs/adapters.md, "Adapters that
// need your code"). No telemetry sink is installed here beyond the analytics one the adapter
// adds, so nothing else is reported; the tests install a recording one. The analytics consent
// starts undecided: nothing is sent until the home page's buttons say so (a real app asks, and
// stores the answer in startup.dart).
Future<void> main() {
  FespalierPush.configure(
    source: demoPush,
    route: pushRoute,
    onToken: sendToken,
  );
  FespalierAnalytics.configure(demoAnalytics, screenName: screenName);
  return AppMain.run();
}
