import 'package:downloads/app.main.g.dart';
import 'package:downloads/setup.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:http/http.dart' as http;

// A package that needs the app's own code is configured before the adapters run, which is
// AppMain.run() (docs/adapters.md, "Adapters that need your code"): the pubspec carries no
// per-adapter options. The app's one transport is built here, `HttpClientTransport` over
// `package:http` (or `DioTransport` over Dio), and the foreground backend downloads through it
// into the folders path_provider names; the registry is a JSON file in the support folder.
Future<void> main() {
  configureDownloads(transport: HttpClientTransport(http.Client()));
  return AppMain.run();
}
