import 'package:downloads/app.main.g.dart';
import 'package:downloads/setup.dart';

// A package that needs the app's own code is configured before the adapters run, which is
// AppMain.run() (docs/adapters.md, "Adapters that need your code"): the pubspec carries no
// per-adapter options. Here the foreground backend downloads over `package:http` into the
// folders path_provider names, and the registry is a JSON file in the support folder.
Future<void> main() {
  configureDownloads();
  return AppMain.run();
}
