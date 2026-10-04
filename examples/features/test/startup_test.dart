// The generated main() (lib/app.main.g.dart): startup.dart, splash.dart and app.dart run
// together, in the order the README says. Every step waits on microtasks only, so the tests
// are deterministic.
import 'dart:async';

import 'package:features/app.g.dart';
import 'package:features/app.main.g.dart';
import 'package:features/app/startup.dart';
import 'package:features/auth.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_storage/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _BrokenStore extends SessionStore {
  @override
  Future<bool> restore() async => throw StateError('disk is full');
}

class _GatedStore extends SessionStore {
  _GatedStore(this.answer);

  final Future<bool> answer;

  @override
  Future<bool> restore() => answer;
}

bool signedIn(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    ).read(session);

void main() {
  setUp(startupLog.clear);
  // startup() opens shared preferences for the team's dataCache: an in-memory store for each test.
  setUp(fakePrefsStore);
  tearDown(() => sessionStore = const SessionStore());

  testWidgets('run(): the zone, then startup in it, then the observers', (
    tester,
  ) async {
    sessionStore = const SessionStore(signedIn: true);
    await AppMain.run();
    // The root is attached in a timer of the zone, so startup() runs in it too; the observers
    // are read after startup(), once.
    await tester.pumpAndSettle();
    expect(startupLog, ['zone', 'startup in zone', 'providerObservers']);
    expect(find.text('Starting…'), findsNothing);
    // The override startup() returned is in the app's ProviderScope.
    expect(signedIn(tester), isTrue);
  });

  testWidgets('the splash shows until startup() is done, then the app', (
    tester,
  ) async {
    final restored = Completer<bool>();
    sessionStore = _GatedStore(restored.future);
    await tester.pumpWidget(AppMain.root());
    expect(find.text('Starting…'), findsOneWidget);
    expect(find.byType(Scaffold), findsNothing);
    // The observers wait for startup(): they are read once it has finished.
    expect(startupLog, ['startup']);

    restored.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Starting…'), findsNothing);
    expect(signedIn(tester), isTrue);
    expect(startupLog, ['startup', 'providerObservers']);
  });

  testWidgets(
    'a failing startup() shows the splash with the error, and retries',
    (tester) async {
      sessionStore = _BrokenStore();
      await tester.pumpWidget(AppMain.root());
      await tester.pumpAndSettle();
      // Reported to FlutterError.onError, which is where a crash reporter listens.
      expect(tester.takeException(), isA<StateError>());
      expect(
        find.text("Couldn't restore the session: Bad state: disk is full"),
        findsOneWidget,
      );

      sessionStore = const SessionStore(signedIn: true);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't restore"), findsNothing);
      expect(signedIn(tester), isTrue);
    },
  );

  testWidgets('pumpRouter(app: AppMain.app) boots a page in the app around it',
      (
    tester,
  ) async {
    await pumpRouter(tester, AppRoutes.router(), app: AppMain.app);
    expect(find.byType(Scaffold), findsWidgets);
    // startup() did not run: tests pass what it would override.
    expect(startupLog, isEmpty);
  });
}
