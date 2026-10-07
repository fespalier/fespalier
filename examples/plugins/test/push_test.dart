// fespalier_push through the generated AppAdapters: a cold start and a tap while the app runs
// open typed routes, marked `source=notification`, and the guards still run. The app is
// AppMain.root(), as main() runs it, with FakePushSource in place of the vendor SDK.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_push/fespalier_push.dart';
import 'package:fespalier_push/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugins/app.g.dart';
import 'package:plugins/app.main.g.dart';
import 'package:plugins/push.dart';

void main() {
  late RecordingTelemetry rec;
  late FakePushSource push;

  setUp(() {
    FespalierPush.debugReset();
    sentTokens.clear();
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
  });
  tearDown(() {
    FespalierTelemetry.install(null);
    FespalierPush.debugReset();
  });

  /// main() on the way to runApp: the adapters' launch() first, then the app around the router.
  Future<void> boot(
    WidgetTester tester,
    FakePushSource source, {
    void Function(String)? onToken,
  }) async {
    push = source;
    addTearDown(push.close);
    FespalierPush.configure(source: push, route: pushRoute, onToken: onToken);
    final launch = await AppAdapters.launch();
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

  String here(WidgetTester tester) => currentLocation(tester);

  int navigations() =>
      rec.log.where((l) => l.contains('start navigate')).length;

  testWidgets('a cold start from a notification opens the order', (
    tester,
  ) async {
    await boot(
      tester,
      FakePushSource(
        initial: const PushMessage(id: 'c1', data: {'link': '/orders/42'}),
      ),
    );
    expect(find.text('Order 42'), findsOneWidget);
    expect(here(tester), '/orders/42');
    expect(
      rec.log,
      contains('#1 start custom fespalier.push.open fespalier.push.state=cold'),
    );
    expect(
      rec.log.where((l) => l.contains('start navigate')).first,
      contains('source=notification'),
    );
  });

  testWidgets('no notification: the app opens at home', (tester) async {
    await boot(tester, FakePushSource());
    expect(find.text('Signed out'), findsOneWidget);
    expect(rec.log.where((l) => l.contains('fespalier.push')), isEmpty);
  });

  testWidgets('a tap while the app runs opens the order, as a notification', (
    tester,
  ) async {
    await boot(tester, FakePushSource());
    push.tap(const PushMessage(id: 'w1', data: {'link': '/orders/7'}));
    await tester.pumpAndSettle();
    expect(find.text('Order 7'), findsOneWidget);
    expect(
      rec.log.where((l) => l.contains('start navigate /orders/7')),
      everyElement(contains('source=notification')),
    );
    expect(rec.log, contains(contains('fespalier.push.state=warm')));
    expect(rec.log, contains(contains('fespalier.push.routed=true')));
  });

  testWidgets('the buttons of the home page are taps through the same path', (
    tester,
  ) async {
    await boot(tester, demoPush);
    await tester.tap(find.text('Simulate a tap: order 42'));
    await tester.pumpAndSettle();
    expect(find.text('Order 42'), findsOneWidget);
  });

  testWidgets('a signed-out tap on a guarded page lands on login, with from', (
    tester,
  ) async {
    await boot(tester, FakePushSource());
    push.tap(const PushMessage(id: 'g1', data: {'link': '/account'}));
    await tester.pumpAndSettle();
    expect(find.text('Log in to see /account'), findsOneWidget);
    expect(here(tester), '/login?from=%2Faccount');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(here(tester), '/account');
  });

  testWidgets('a signed-in tap goes straight to the guarded page', (
    tester,
  ) async {
    await boot(tester, FakePushSource());
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    push.tap(const PushMessage(id: 'g2', data: {'link': '/account'}));
    await tester.pumpAndSettle();
    expect(find.text('Account'), findsWidgets);
    expect(here(tester), '/account');
  });

  testWidgets('a link the app does not know, or a foreign one, is ignored', (
    tester,
  ) async {
    await boot(tester, FakePushSource());
    final before = navigations();
    for (final link in [
      'https://evil.example.com/orders/1',
      '//evil.example.com/orders/1',
      '/nowhere',
    ]) {
      push.tap(PushMessage(data: {'link': link}));
      await tester.pumpAndSettle();
    }
    expect(find.text('Signed out'), findsOneWidget);
    expect(navigations(), before);
    expect(rec.log, contains(contains('fespalier.push.routed=false')));
  });

  testWidgets('the cold-start tap seen again on the tap stream opens once', (
    tester,
  ) async {
    await boot(
      tester,
      FakePushSource(
        initial: const PushMessage(id: 'dup', data: {'link': '/orders/1'}),
      ),
    );
    final before = navigations();
    push.tap(const PushMessage(id: 'dup', data: {'link': '/orders/1'}));
    await tester.pumpAndSettle();
    expect(navigations(), before);
    expect(here(tester), '/orders/1');
  });

  testWidgets('onToken gets the token and its refresh; nothing is requested', (
    tester,
  ) async {
    final tokens = <String>[];
    await boot(tester, FakePushSource(token: 't1'), onToken: tokens.add);
    push.emitToken('t2');
    await tester.pump();
    expect(tokens, ['t1', 't2']);
    expect(push.permissionRequests, 0);
  });
}
