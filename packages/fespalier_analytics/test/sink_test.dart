// The sink on a hand-built router with the attach call the generated file makes
// (`telemetryAttach`): what a backend is told, and when it is told nothing. The generated wiring
// (AppAdapters, `telemetry: true`) is proved end to end by examples/plugins.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_analytics/fespalier_analytics.dart';
import 'package:fespalier_analytics/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _page(String label) => Scaffold(body: Text(label));

GoRouter _router({String initial = '/home'}) {
  final r = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/home', builder: (_, _) => _page('home')),
      GoRoute(
        path: '/items/:id',
        builder: (_, s) => _page('item ${s.pathParameters['id']}'),
      ),
      GoRoute(path: '/other', builder: (_, _) => _page('other')),
      GoRoute(path: '/admin', builder: (_, _) => _page('admin')),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => shell,
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: '/t1', builder: (_, _) => _page('t1'))],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/t2', builder: (_, _) => _page('t2'))],
          ),
        ],
      ),
    ],
  );
  telemetryAttach(r, base: () => '/');
  return r;
}

void main() {
  late RecordingAnalytics backend;

  setUp(() {
    FespalierAnalytics.debugReset();
    backend = RecordingAnalytics();
  });
  tearDown(() {
    FespalierTelemetry.install(null);
    FespalierAnalytics.debugReset();
  });

  /// Configures, installs and boots a router at [initial].
  Future<GoRouter> boot(
    WidgetTester tester, {
    AnalyticsConsent consent = AnalyticsConsent.granted,
    String initial = '/home',
    String? Function(String)? screenName,
    bool returningViews = true,
    bool screenTime = true,
    AnalyticsBackend? using,
  }) async {
    FespalierAnalytics.configure(
      using ?? backend,
      consent: consent,
      screenName: screenName,
      returningViews: returningViews,
      screenTime: screenTime,
    );
    FespalierAnalytics.install();
    final r = _router(initial: initial);
    await pumpRouter(tester, r);
    return r;
  }

  group('screen views', () {
    testWidgets('the first screen is a view, named by its pattern', (
      tester,
    ) async {
      await boot(tester);
      expect(backend.views, [
        const ScreenView(name: '/home', pattern: '/home'),
      ]);
    });

    testWidgets('a navigation is one view, and the screen left is timed', (
      tester,
    ) async {
      final r = await boot(tester);
      backend.clear();
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(backend.views, [
        const ScreenView(name: '/items/:id', pattern: '/items/:id'),
      ]);
      expect(backend.times, hasLength(1));
      expect(backend.times.single.pattern, '/home');
      expect(
        backend.times.single.duration,
        greaterThanOrEqualTo(Duration.zero),
      );
    });

    testWidgets(
      'a pop is a returning view of the page below, and times the one left',
      (tester) async {
        final r = await boot(tester);
        unawaited(r.push<void>('/other'));
        await tester.pumpAndSettle();
        backend.clear();
        r.pop();
        await tester.pumpAndSettle();
        expect(backend.log.map((l) => l.replaceAll(RegExp(r' \d+ms'), '')), [
          'time /other',
          'view /home returning',
        ]);
      },
    );

    testWidgets('going back to a tab is a returning view', (tester) async {
      final r = await boot(tester, initial: '/t1');
      r.go('/t2');
      await tester.pumpAndSettle();
      backend.clear();
      r.go('/t1');
      await tester.pumpAndSettle();
      expect(backend.views, [
        const ScreenView(name: '/t1', pattern: '/t1', returning: true),
      ]);
    });

    testWidgets('returningViews: false drops the returning view only', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/t1', returningViews: false);
      r.go('/t2');
      await tester.pumpAndSettle();
      r.go('/t1');
      await tester.pumpAndSettle();
      expect(backend.views.map((v) => v.pattern), ['/t1', '/t2']);
    });

    testWidgets('screenTime: false sends views and no time', (tester) async {
      final r = await boot(tester, screenTime: false);
      r.go('/other');
      await tester.pumpAndSettle();
      expect(backend.views, hasLength(2));
      expect(backend.times, isEmpty);
    });

    testWidgets('a source from navigateFrom is carried to the view', (
      tester,
    ) async {
      final r = await boot(tester);
      backend.clear();
      navigateFrom(NavigationSource.notification, () => r.go('/items/3'));
      await tester.pumpAndSettle();
      expect(backend.views.single.source, NavigationSource.notification);
      r.go('/other');
      await tester.pumpAndSettle();
      expect(backend.views.last.source, isNull);
    });

    testWidgets('a not-found page is not a screen', (tester) async {
      final r = await boot(tester);
      backend.clear();
      r.go('/nowhere');
      await tester.pumpAndSettle();
      expect(backend.views, isEmpty);
    });
  });

  group('screenName', () {
    testWidgets(
      'maps a pattern to a name, and null skips the screen and its time',
      (tester) async {
        final r = await boot(
          tester,
          screenName: (p) => switch (p) {
            '/home' => 'Home',
            '/admin' => null,
            _ => p.substring(1),
          },
        );
        r.go('/admin');
        await tester.pumpAndSettle();
        r.go('/other');
        await tester.pumpAndSettle();
        expect(backend.views.map((v) => v.name), ['Home', 'other']);
        expect(backend.views.map((v) => v.pattern), ['/home', '/other']);
        expect(backend.times.map((t) => t.name), ['Home']);
      },
    );

    testWidgets('an empty name is a skip too', (tester) async {
      await boot(tester, screenName: (_) => '');
      expect(backend.views, isEmpty);
    });
  });

  group('consent', () {
    testWidgets('undecided and denied: nothing reaches the backend', (
      tester,
    ) async {
      for (final consent in [
        AnalyticsConsent.undecided,
        AnalyticsConsent.denied,
      ]) {
        final fresh = RecordingAnalytics();
        final r = await boot(tester, consent: consent, using: fresh);
        r.go('/items/1');
        await tester.pumpAndSettle();
        r.go('/other');
        await tester.pumpAndSettle();
        expect(fresh.log, isEmpty, reason: consent.name);
        FespalierTelemetry.install(null);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets(
      'granting replays nothing: the next screen is the first reported',
      (tester) async {
        final r = await boot(tester, consent: AnalyticsConsent.undecided);
        r.go('/items/1');
        await tester.pumpAndSettle();
        expect(backend.log, isEmpty);

        FespalierAnalytics.sink!.consent = AnalyticsConsent.granted;
        expect(backend.consents, [AnalyticsConsent.granted]);
        // The screen that was open when consent came is not reported, and its leave is not
        // timed: it was never viewed.
        r.go('/other');
        await tester.pumpAndSettle();
        expect(backend.views.map((v) => v.pattern), ['/other']);
        expect(backend.times, isEmpty);
      },
    );

    testWidgets('revoking stops everything at once and forgets what was open', (
      tester,
    ) async {
      final r = await boot(tester);
      backend.clear();
      FespalierAnalytics.sink!.consent = AnalyticsConsent.denied;
      expect(backend.consents, [AnalyticsConsent.denied]);
      r.go('/other');
      await tester.pumpAndSettle();
      expect(backend.views, isEmpty);
      expect(backend.times, isEmpty);

      // Granted again: /home was left while denied, so its time is not sent later.
      FespalierAnalytics.sink!.consent = AnalyticsConsent.granted;
      r.go('/items/2');
      await tester.pumpAndSettle();
      expect(backend.views.map((v) => v.pattern), ['/items/:id']);
      expect(backend.times, isEmpty);
    });

    test('the same value again does not call the backend', () {
      FespalierAnalytics.configure(backend);
      final sink = FespalierAnalytics.sink!;
      sink.consent = AnalyticsConsent.undecided;
      expect(backend.consents, isEmpty);
      sink.consent = AnalyticsConsent.granted;
      sink.consent = AnalyticsConsent.granted;
      expect(backend.consents, [AnalyticsConsent.granted]);
    });

    test(
      'a backend that throws on consentChanged is reported, not rethrown',
      () {
        final reported = <FlutterErrorDetails>[];
        final original = FlutterError.onError;
        FlutterError.onError = reported.add;
        addTearDown(() => FlutterError.onError = original);
        FespalierAnalytics.configure(RecordingAnalytics(throwing: true));
        FespalierAnalytics.sink!.consent = AnalyticsConsent.granted;
        expect(FespalierAnalytics.sink!.consent, AnalyticsConsent.granted);
        expect(reported, hasLength(1));
        expect(reported.single.library, 'fespalier_analytics');
      },
    );
  });

  group('a backend that throws', () {
    testWidgets('does not stop the app or the other sinks', (tester) async {
      final other = RecordingTelemetry();
      final failing = RecordingAnalytics(throwing: true);
      FespalierAnalytics.configure(failing, consent: AnalyticsConsent.granted);
      FespalierTelemetry.install(
        FespalierTelemetry.combine([FespalierAnalytics.sink!, other]),
      );
      final r = _router();
      await pumpRouter(tester, r);
      r.go('/other');
      await tester.pumpAndSettle();
      expect(find.text('other'), findsOneWidget);
      expect(failing.views, hasLength(2));
      expect(other.log, contains(contains('page enter /other')));
    });
  });

  group('privacy', () {
    test(
      'a navigation source that is not a NavigationSource value is dropped',
      () {
        FespalierAnalytics.configure(
          backend,
          consent: AnalyticsConsent.granted,
        );
        final sink = FespalierAnalytics.sink!;
        for (final source in [
          'banner',
          'user@example.com',
          NavigationSource.link,
        ]) {
          final token = sink.start(
            TelemetryStart(TelemetryOp.navigate, source: source),
          );
          sink.page(token, const TelemetryPage(TelemetryPageKind.enter, '/a'));
        }
        expect(backend.views.map((v) => v.source), [
          null,
          null,
          NavigationSource.link,
        ]);
      },
    );

    test('a view whose backend threw is not timed', () {
      FespalierAnalytics.configure(
        RecordingAnalytics(throwing: true),
        consent: AnalyticsConsent.granted,
      );
      final sink = FespalierAnalytics.sink!;
      expect(
        () =>
            sink.page(null, const TelemetryPage(TelemetryPageKind.enter, '/a')),
        throwsStateError,
      );
      sink.page(
        null,
        const TelemetryPage(
          TelemetryPageKind.leave,
          '/a',
          duration: Duration(seconds: 1),
        ),
      );
      expect((sink.backend as RecordingAnalytics).times, isEmpty);
    });

    testWidgets(
      'no URL, query, fragment or segment value ever reaches a backend',
      (tester) async {
        final r = await boot(tester);
        navigateFrom(
          NavigationSource.link,
          () => r.go('/items/secret-42?token=abc123&email=a@b.c#frag-9'),
        );
        await tester.pumpAndSettle();
        r.go('/other');
        await tester.pumpAndSettle();
        expect(backend.strings, isNotEmpty);
        for (final s in backend.strings) {
          for (final leak in [
            'secret-42',
            'token',
            'abc123',
            'a@b.c',
            'frag',
            '?',
          ]) {
            expect(s, isNot(contains(leak)), reason: s);
          }
        }
        expect(backend.log.join('\n'), isNot(contains('secret-42')));
      },
    );
  });

  group('next to another sink', () {
    testWidgets('each sink gets its own token and the source reaches ours', (
      tester,
    ) async {
      final other = RecordingTelemetry();
      FespalierAnalytics.configure(backend, consent: AnalyticsConsent.granted);
      FespalierTelemetry.install(other);
      FespalierAnalytics.install();
      final r = _router();
      await pumpRouter(tester, r);
      backend.clear();
      navigateFrom(NavigationSource.shortcut, () => r.go('/other'));
      await tester.pumpAndSettle();
      expect(backend.views.single.source, NavigationSource.shortcut);
      expect(other.log, contains(contains('page enter /other')));
    });
  });
}
