// fespalier must not make apps flaky: with the sink installed a sync guard, `data()` or action
// stays sync and the very object comes back, a Future is never replaced, an SDK that fails costs
// an event and never a feature, and nothing is left pending (a timer would fail these tests).
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_sentry/fespalier_sentry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'support.dart';

/// A hub that is up and whose every call throws.
final class BrokenHub implements Hub {
  @override
  bool get isEnabled => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('the SDK is broken: ${invocation.memberName}');
}

/// A hub that is up and whose every call that returns a `Future` fails later.
final class FlakyHub implements Hub {
  @override
  bool get isEnabled => true;

  @override
  Future<SentryId> captureException(
    dynamic throwable, {
    dynamic stackTrace,
    Hint? hint,
    SentryMessage? message,
    ScopeCallback? withScope,
  }) async => throw StateError('captureException failed');

  @override
  Future<void> addBreadcrumb(Breadcrumb crumb, {Hint? hint}) async =>
      throw StateError('addBreadcrumb failed');

  @override
  FutureOr<void> configureScope(ScopeCallback callback) async =>
      throw StateError('configureScope failed');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('not under test: ${invocation.memberName}');
}

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  group('the value that comes back is the very one', () {
    test('a sync data() is a value, in the same call', () {
      Rig();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(syncData), 'sync');
    });

    test('a data() that returns a Future gives that Future', () {
      Rig(tracing: true);
      final future = Future<String>.value('x');
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final provider = Provider.autoDispose<Future<String>>(
        (ref) =>
            traceDataCall(ref, 'd1', null, () => future, telemetry: dataSite),
      );
      expect(identical(c.read(provider), future), isTrue);
    });

    test('a data() with tracing: true that returns an object gives it', () {
      Rig(tracing: true);
      final object = Object();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final provider = Provider.autoDispose<Object>(
        (ref) =>
            traceDataCall(ref, 'd1', null, () => object, telemetry: dataSite),
      );
      expect(identical(c.read(provider), object), isTrue);
    });

    test('an action gives its result, and an error its own', () async {
      Rig(tracing: true);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final echo = actionProvider<String, String>(
        (ref, input) async => input,
        invalidates: () => const [],
        telemetry: actionSite,
      );
      c.listen(echo, (_, _) {});
      expect(await c.read(echo.notifier).call('a'), 'a');
      final error = StateError('same object');
      final fail = actionProvider<String, String>(
        (ref, input) async => throw error,
        invalidates: () => const [],
        telemetry: actionSite,
      );
      c.listen(fail, (_, _) {});
      await expectLater(c.read(fail.notifier).call('a'), throwsA(same(error)));
    });

    for (final tracing in [false, true]) {
      testWidgets('a sync guard still redirects (tracing: $tracing)', (
        tester,
      ) async {
        checkout = () => '/login';
        final rig = Rig(tracing: tracing);
        final r = await rig.boot(tester);
        r.go('/checkout');
        await tester.pumpAndSettle();
        expect(find.text('login'), findsOneWidget);
      });
    }
  });

  group('without an SDK', () {
    test('the sink started on no hub does nothing, and says so with null', () {
      // The hub of `Sentry.init`, which was not called: Sentry is off.
      final sink = FespalierSentry();
      expect(
        sink.start(const TelemetryStart(TelemetryOp.data, site: dataSite)),
        isNull,
      );
      sink.end(null, const TelemetryEnd(TelemetryOutcome.data));
      sink.page(null, const TelemetryPage(TelemetryPageKind.enter, '/home'));
    });

    testWidgets('an app with it installed runs, and records nothing', (
      tester,
    ) async {
      FespalierTelemetry.install(FespalierSentry());
      final r = router();
      await pumpRouter(tester, r);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(find.text('item 7'), findsOneWidget);
    });
  });

  group('an SDK that fails costs an event, never a feature', () {
    testWidgets('every call throws', (tester) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      FespalierTelemetry.install(FespalierSentry(hub: BrokenHub()));
      final r = router();
      await pumpRouter(tester, r);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(find.text('failed'), findsOneWidget);
      r.go('/other');
      await tester.pumpAndSettle();
      expect(find.text('other'), findsOneWidget);
    });

    testWidgets('with tracing: true too', (tester) async {
      FespalierTelemetry.install(
        FespalierSentry(hub: BrokenHub(), tracing: true),
      );
      final r = router();
      await pumpRouter(tester, r);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(find.text('item 7'), findsOneWidget);
    });

    testWidgets('every call that returns a Future fails, and no error is '
        'unhandled', (tester) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      FespalierTelemetry.install(FespalierSentry(hub: FlakyHub()));
      final r = router();
      await pumpRouter(tester, r);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(find.text('failed'), findsOneWidget);
    });
  });

  testWidgets('no timer, no frame and no microtask is left behind', (
    tester,
  ) async {
    final rig = Rig(tracing: true);
    final r = await rig.boot(tester);
    r.go('/shop');
    await tester.pumpAndSettle();
    r.go('/items/7');
    await tester.pumpAndSettle();
    r.go('/nowhere');
    await tester.pumpAndSettle();
    // testWidgets itself fails the test on a pending timer, and a frame that was scheduled
    // without a reason would make the next line pump.
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
