// fespalier_analytics through the generated AppAdapters: screen views by route pattern, sent only
// while the person has agreed. The app is AppMain.root(), as main() runs it, with a recording
// backend in place of the vendor SDK.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_analytics/fespalier_analytics.dart';
import 'package:fespalier_analytics/testing.dart';
import 'package:fespalier_push/fespalier_push.dart';
import 'package:fespalier_push/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugins/analytics.dart';
import 'package:plugins/app.g.dart';
import 'package:plugins/app.main.g.dart';
import 'package:plugins/push.dart';

void main() {
  late RecordingAnalytics analytics;
  late FakePushSource push;

  setUp(() {
    FespalierAnalytics.debugReset();
    FespalierPush.debugReset();
    analytics = demoAnalytics..clear();
    push = FakePushSource();
  });
  tearDown(() {
    FespalierTelemetry.install(null);
    FespalierAnalytics.debugReset();
    FespalierPush.debugReset();
  });

  /// main() on the way to runApp: the adapters' beforeRun() and launch(), then the app around the
  /// router.
  Future<void> boot(
    WidgetTester tester, {
    AnalyticsConsent consent = AnalyticsConsent.undecided,
  }) async {
    addTearDown(push.close);
    FespalierPush.configure(source: push, route: pushRoute);
    FespalierAnalytics.configure(
      analytics,
      screenName: screenName,
      consent: consent,
    );
    await AppAdapters.beforeRun();
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

  Future<void> tapButton(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(find.text(text), 200);
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  testWidgets('the first screen is a view, by a name of the app\'s choosing', (
    tester,
  ) async {
    await boot(tester, consent: AnalyticsConsent.granted);
    expect(analytics.views, [const ScreenView(name: 'Home', pattern: '/')]);
  });

  testWidgets('undecided: nothing is sent, and answering sends from then on', (
    tester,
  ) async {
    await boot(tester);
    push.tap(const PushMessage(id: 't1', data: {'link': '/orders/42'}));
    await tester.pumpAndSettle();
    expect(find.text('Order 42'), findsOneWidget);
    expect(analytics.log, isEmpty);

    // The home page is behind the order now; go back to it and answer.
    push.tap(const PushMessage(id: 't2', data: {'link': '/'}));
    await tester.pumpAndSettle();
    await tapButton(tester, 'Allow analytics');
    expect(find.text('Analytics: granted'), findsOneWidget);
    expect(analytics.consents, [AnalyticsConsent.granted]);
    // Nothing that was dropped is sent now.
    expect(analytics.views, isEmpty);

    push.tap(const PushMessage(id: 't3', data: {'link': '/orders/7'}));
    await tester.pumpAndSettle();
    expect(analytics.views.map((v) => v.name), ['Order']);
    expect(analytics.times.map((t) => t.pattern), isEmpty);
  });

  testWidgets('refusing stops the views at once', (tester) async {
    await boot(tester, consent: AnalyticsConsent.granted);
    await tapButton(tester, 'Refuse analytics');
    expect(analytics.consents, [AnalyticsConsent.denied]);
    analytics.clear();
    push.tap(const PushMessage(id: 'r1', data: {'link': '/orders/1'}));
    await tester.pumpAndSettle();
    expect(find.text('Order 1'), findsOneWidget);
    expect(analytics.log, isEmpty);
  });

  testWidgets('a notification tap is a view marked with its source', (
    tester,
  ) async {
    await boot(tester, consent: AnalyticsConsent.granted);
    analytics.clear();
    push.tap(const PushMessage(id: 'n1', data: {'link': '/orders/9'}));
    await tester.pumpAndSettle();
    expect(analytics.views, [
      const ScreenView(
        name: 'Order',
        pattern: '/orders/:id',
        source: NavigationSource.notification,
      ),
    ]);
    // /orders/:id is a child of the home route: home is covered, not left, so it is not timed.
    expect(analytics.times, isEmpty);
  });

  testWidgets('a screen the app names null is skipped: the login page', (
    tester,
  ) async {
    await boot(tester, consent: AnalyticsConsent.granted);
    analytics.clear();
    // Signed out, a guarded page lands on the login page.
    push.tap(const PushMessage(id: 'g1', data: {'link': '/account'}));
    await tester.pumpAndSettle();
    expect(find.text('Log in to see /account'), findsOneWidget);
    expect(analytics.views, isEmpty);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(analytics.views.map((v) => v.pattern), ['/account']);
  });

  testWidgets('a segment value never reaches the backend', (tester) async {
    await boot(tester, consent: AnalyticsConsent.granted);
    push.tap(
      const PushMessage(
        id: 'p1',
        data: {'link': '/orders/424242?coupon=SECRET#top'},
      ),
    );
    await tester.pumpAndSettle();
    expect(analytics.views.map((v) => v.pattern), contains('/orders/:id'));
    for (final s in analytics.strings) {
      expect(s, isNot(anyOf(contains('424242'), contains('SECRET'))));
    }
  });
}
