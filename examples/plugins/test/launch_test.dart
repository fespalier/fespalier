// fespalier_launch through the generated AppAdapters: a home-screen shortcut or a widget tap, cold
// or while the app runs, opens a typed route, marked `source=shortcut` or `source=widget`, and the
// guards still run. The app is AppMain.root(), as main() runs it, with FakeLaunchSource in place of
// quick_actions and home_widget.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_launch/fespalier_launch.dart';
import 'package:fespalier_launch/testing.dart';
import 'package:fespalier_push/fespalier_push.dart';
import 'package:fespalier_push/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugins/app.g.dart';
import 'package:plugins/app.main.g.dart';
import 'package:plugins/launch.dart';
import 'package:plugins/push.dart';

void main() {
  late RecordingTelemetry rec;
  late FakeLaunchSource shortcuts;
  late FakeLaunchSource widgets;

  setUp(() {
    FespalierLaunch.debugReset();
    FespalierPush.debugReset();
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
  });
  tearDown(() {
    FespalierTelemetry.install(null);
    FespalierLaunch.debugReset();
    FespalierPush.debugReset();
  });

  /// main() on the way to runApp: the adapters' launch() first, then the app around the router.
  /// [initial] is the action that opened the app, given to the source of its kind.
  Future<void> boot(
    WidgetTester tester, {
    List<LaunchSource>? sources,
    LaunchAction? initial,
    void Function()? whileStarting,
  }) async {
    shortcuts = FakeLaunchSource(
      initial: initial is ShortcutAction ? initial : null,
    );
    widgets = FakeLaunchSource(
      initial: initial is WidgetAction ? initial : null,
    );
    addTearDown(shortcuts.close);
    addTearDown(widgets.close);
    final push = FakePushSource();
    addTearDown(push.close);
    FespalierPush.configure(source: push, route: pushRoute);
    FespalierLaunch.configure(
      sources: sources ?? [shortcuts, widgets],
      route: launchRoute,
    );
    final launch = await AppAdapters.launch();
    if (whileStarting != null) {
      // startup() is running: no router yet, nobody but the adapter on the actions streams.
      whileStarting();
      await tester.pump();
    }
    await tester.pumpWidget(
      AppMain.root(
        router: () => AppRoutes.router(
          launch: launch,
          observers: AppMain.routerObservers(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  int navigations() =>
      rec.log.where((l) => l.contains('start navigate')).length;

  testWidgets('a cold start from a shortcut opens the order, marked shortcut', (
    tester,
  ) async {
    await boot(tester, initial: const ShortcutAction(ShortcutTypes.lastOrder));
    expect(find.text('Order 42'), findsOneWidget);
    expect(currentLocation(tester), '/orders/42');
    expect(
      rec.log,
      contains(
        '#1 start custom fespalier.launch.open fespalier.launch.kind=shortcut fespalier.launch.state=cold',
      ),
    );
    expect(
      rec.log.where((l) => l.contains('start navigate')).first,
      contains('source=shortcut'),
    );
  });

  testWidgets('a cold start from a widget opens the order, marked widget', (
    tester,
  ) async {
    await boot(tester, initial: WidgetAction(Uri.parse('plugins:///orders/7')));
    expect(find.text('Order 7'), findsOneWidget);
    expect(currentLocation(tester), '/orders/7');
    expect(
      rec.log.where((l) => l.contains('start navigate')).first,
      contains('source=widget'),
    );
  });

  testWidgets('no shortcut and no widget: the app opens at home', (
    tester,
  ) async {
    await boot(tester);
    expect(find.text('Signed out'), findsOneWidget);
    expect(rec.log.where((l) => l.contains('fespalier.launch')), isEmpty);
  });

  testWidgets(
    'a shortcut while the app runs opens the order, marked shortcut',
    (tester) async {
      await boot(tester);
      shortcuts.shortcut(ShortcutTypes.lastOrder);
      await tester.pumpAndSettle();
      expect(find.text('Order 42'), findsOneWidget);
      expect(
        rec.log.where((l) => l.contains('start navigate /orders/42')),
        everyElement(contains('source=shortcut')),
      );
      expect(rec.log, contains(contains('fespalier.launch.state=warm')));
      expect(rec.log, contains(contains('fespalier.launch.routed=true')));
    },
  );

  testWidgets(
    'a widget tap while the app runs opens the order, marked widget',
    (tester) async {
      await boot(tester);
      widgets.widget(Uri.parse('plugins:///orders/7'));
      await tester.pumpAndSettle();
      expect(find.text('Order 7'), findsOneWidget);
      expect(
        rec.log.where((l) => l.contains('start navigate /orders/7')),
        everyElement(contains('source=widget')),
      );
      expect(rec.log, contains(contains('fespalier.launch.state=warm')));
    },
  );

  testWidgets(
    'a signed-out shortcut to a guarded page lands on login, with from',
    (tester) async {
      await boot(tester);
      shortcuts.shortcut(ShortcutTypes.account);
      await tester.pumpAndSettle();
      expect(find.text('Log in to see /account'), findsOneWidget);
      expect(currentLocation(tester), '/login?from=%2Faccount');
    },
  );

  testWidgets('a URI or a shortcut the app does not map stays at home', (
    tester,
  ) async {
    await boot(tester);
    final before = navigations();
    for (final uri in [
      'https://evil.example.com/orders/1',
      'plugins:///nowhere',
      'myapp:///orders/1',
    ]) {
      widgets.widget(Uri.parse(uri));
      await tester.pumpAndSettle();
    }
    shortcuts.shortcut('not_ours');
    await tester.pumpAndSettle();
    expect(find.text('Signed out'), findsOneWidget);
    expect(navigations(), before);
    expect(rec.log, contains(contains('fespalier.launch.routed=false')));
  });

  testWidgets(
    'a shortcut while the app starts opens once, after the first frame',
    (tester) async {
      await boot(
        tester,
        whileStarting: () => shortcuts.shortcut(ShortcutTypes.lastOrder),
      );
      expect(find.text('Order 42'), findsOneWidget);
      expect(
        rec.log.where((l) => l.contains('start navigate /orders/42')),
        hasLength(1),
      );
      expect(rec.log, contains(contains('fespalier.launch.state=warm')));
    },
  );

  testWidgets('the shortcut button of the home page opens the order', (
    tester,
  ) async {
    await boot(tester, sources: [demoShortcuts, demoWidget]);
    await tester.scrollUntilVisible(
      find.text('Simulate a shortcut: last order'),
      200,
    );
    await tester.tap(find.text('Simulate a shortcut: last order'));
    await tester.pumpAndSettle();
    expect(find.text('Order 42'), findsOneWidget);
  });

  testWidgets('the widget button of the home page opens the order', (
    tester,
  ) async {
    await boot(tester, sources: [demoShortcuts, demoWidget]);
    await tester.scrollUntilVisible(
      find.text('Simulate a widget tap: order 7'),
      200,
    );
    await tester.tap(find.text('Simulate a widget tap: order 7'));
    await tester.pumpAndSettle();
    expect(find.text('Order 7'), findsOneWidget);
  });
}
