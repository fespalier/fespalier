import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live/app.g.dart';
import 'package:live/app.main.g.dart';
import 'package:live/demo/live_server.dart';
import 'package:live/wiring.dart';

/// The app over the in-process demo server, as `flutter run` starts it, with the tick fired by hand:
/// the app's own timer (lib/ticker.dart) would leave one pending.
class Live {
  /// The app over [server] (a fresh demo server by default) and [overrides] (a fake in its place).
  Live({LiveServer? server, this.overrides = const []})
    : server =
          server ?? LiveServer(wordPace: const Duration(milliseconds: 100));

  /// The demo server: the routes tool/server.dart answers, in process.
  final LiveServer server;

  /// What a test puts in the demo server's place.
  final List<Override> overrides;

  late ProviderContainer _container;

  /// Opens [location] with the whole app around it.
  Future<ProviderContainer> open(WidgetTester tester, String location) async =>
      _container = await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: location),
        overrides: [
          liveServer.overrideWithValue(server),
          ...streamTestOverrides(),
          ...overrides,
        ],
        app: AppMain.app,
      );

  /// One tick of the app's timer.
  Future<void> tick(WidgetTester tester) async {
    (_container.read(streamTicker.notifier) as ManualStreamTicker).tick();
    await tester.pumpAndSettle();
  }

  /// The lines of the server's log that start with [prefix].
  List<String> logged(String prefix) =>
      server.log.where((line) => line.startsWith(prefix)).toList();
}

/// Taps the widget that says [text], scrolled into view first.
Future<void> tapText(WidgetTester tester, String text) async {
  final target = find.text(text);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// The connection's status, as the banner says it.
String statusOf(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('status'))).data!;
