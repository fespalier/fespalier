// Telemetry (since 0.8.0): what `FespalierTelemetry` is told while a hand-built router (with the
// call sites the generated file would pass) navigates, guards, loads data, runs an action and
// loads a deferred page. A `RecordingTelemetry` keeps it as lines.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const TelemetrySite guardSite = TelemetrySite(
  'checkout/guard.dart',
  route: '/checkout',
);
const TelemetrySite redirectSite = TelemetrySite(
  'old/redirect.dart',
  route: '/old',
);
const TelemetrySite dataSite = TelemetrySite(
  'items/\$id/data.dart',
  route: '/items/:id',
);
const TelemetrySite actionSite = TelemetrySite(
  'items/\$id/action.dart',
  route: '/items/:id',
  name: 'rename',
);

late RecordingTelemetry rec;

/// What the next call of the guard of `/checkout` answers.
FutureOr<String?> Function() checkout = () => null;

/// What `data()` of an item gives.
Object? Function(int id) itemData = (id) => 'item $id';

final item = FutureProvider.autoDispose.family<String, int>(
  (ref, id) => traceData(
    ref,
    'd1',
    id,
    Future<String>.microtask(() => '${itemData(id)}'),
    telemetry: dataSite,
  ),
);

final Provider<String> syncData = Provider.autoDispose<String>(
  (ref) => traceData(ref, 'd2', null, 'sync', telemetry: dataSite),
);

Widget page(String label) => Scaffold(body: Text(label));

GoRouter router({String initial = '/home'}) {
  final r = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/home', builder: (_, _) => page('home')),
      GoRoute(
        path: '/items/:id',
        builder: (_, s) => page('item ${s.pathParameters['id']}'),
      ),
      GoRoute(path: '/items', builder: (_, _) => page('items')),
      GoRoute(path: '/other', builder: (_, _) => page('other')),
      GoRoute(
        path: '/checkout',
        redirect: (_, state) =>
            traceGuard(state, 'g1@3', checkout(), telemetry: guardSite),
        builder: (_, _) => page('checkout'),
      ),
      GoRoute(
        path: '/old',
        redirect: (_, state) =>
            traceGuard(state, 'r4', '/other', telemetry: redirectSite),
      ),
      GoRoute(path: '/login', builder: (_, _) => page('login')),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => shell,
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: '/t1', builder: (_, _) => page('t1'))],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/t2', builder: (_, _) => page('t2'))],
          ),
        ],
      ),
    ],
  );
  telemetryAttach(r, base: () => '/');
  return r;
}

Future<GoRouter> boot(WidgetTester tester, {String initial = '/home'}) async {
  final r = router(initial: initial);
  await pumpRouter(tester, r);
  return r;
}

void main() {
  setUp(() {
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    checkout = () => null;
    itemData = (id) => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  group('navigations', () {
    testWidgets(
      'the initial one starts at attach and ends at the first frame',
      (tester) async {
        await boot(tester);
        expect(rec.log, [
          '#1 start navigate /home',
          '#1 page enter /home',
          '#1 end navigate ok route=/home kind=initial at=/home',
        ]);
      },
    );

    testWidgets('go: requested, committed, shown', (tester) async {
      final r = await boot(tester);
      rec.log.clear();
      r.go('/items/7');
      expect(rec.log, ['#2 start navigate /items/7']);
      await tester.pumpAndSettle();
      expect(rec.log, [
        '#2 start navigate /items/7',
        '#2 page leave /home',
        '#2 page enter /items/:id',
        '#2 end navigate ok route=/items/:id kind=go from=/home at=/items/7',
      ]);
    });

    testWidgets('push and pop', (tester) async {
      final r = await boot(tester);
      rec.log.clear();
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      expect(rec.log, [
        '#2 start navigate /other',
        '#2 page enter /other',
        '#2 end navigate ok route=/other kind=push from=/home depth=1 at=/other',
      ]);
      rec.log.clear();
      r.pop();
      await tester.pumpAndSettle();
      expect(rec.log, [
        '#3 start navigate (commit)',
        '#3 page leave /other',
        '#3 page focus /home',
        '#3 end navigate ok route=/home kind=pop from=/other at=/home',
      ]);
    });

    testWidgets('replace on a pushed page', (tester) async {
      final r = await boot(tester);
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      rec.log.clear();
      unawaited(r.replace<void>('/items/1'));
      await tester.pumpAndSettle();
      expect(rec.log, [
        '#3 start navigate /items/1',
        '#3 page leave /other',
        '#3 page enter /items/:id',
        '#3 end navigate ok route=/items/:id kind=replace from=/other depth=1 at=/items/1',
      ]);
    });

    testWidgets('a refresh starts no navigation of its own', (tester) async {
      final r = await boot(tester);
      rec.log.clear();
      r.refresh();
      await tester.pumpAndSettle();
      // Nothing was requested and nothing committed: the router answered the same.
      expect(rec.log, isEmpty);
    });

    testWidgets('a tab switch is a navigation', (tester) async {
      final r = await boot(tester, initial: '/t1');
      rec.log.clear();
      r.go('/t2');
      await tester.pumpAndSettle();
      expect(rec.log, [
        '#2 start navigate /t2',
        '#2 page enter /t2',
        '#2 end navigate ok route=/t2 kind=go from=/t1 at=/t2',
      ]);
    });

    testWidgets('a redirect says so', (tester) async {
      final r = await boot(tester);
      rec.log.clear();
      r.go('/old');
      await tester.pumpAndSettle();
      expect(rec.log, [
        '#2 start navigate /old',
        '#3 start redirect old/redirect.dart parent=#2',
        '#3 end redirect redirect -> /other',
        '#2 page leave /home',
        '#2 page enter /other',
        '#2 end navigate ok route=/other kind=go from=/home redirected at=/other',
      ]);
    });

    testWidgets('a location that matches no route is not_found, not an error', (
      tester,
    ) async {
      final r = await boot(tester);
      rec.log.clear();
      r.go('/nowhere');
      await tester.pumpAndSettle();
      expect(rec.log.first, '#2 start navigate /nowhere');
      expect(rec.log.last, startsWith('#2 end navigate not_found kind=go'));
      expect(rec.log, contains('#2 page leave /home'));
    });

    testWidgets('two requests before a commit: the first is superseded', (
      tester,
    ) async {
      final answer = Completer<String?>();
      checkout = () => answer.future;
      final r = await boot(tester);
      rec.log.clear();
      r.go('/checkout');
      await tester.pump();
      r.go('/items/2');
      await tester.pumpAndSettle();
      expect(rec.log, [
        '#2 start navigate /checkout',
        '#3 start guard checkout/guard.dart parent=#2',
        '#2 end navigate superseded',
        '#4 start navigate /items/2',
        '#4 page leave /home',
        '#4 page enter /items/:id',
        '#4 end navigate ok route=/items/:id kind=go from=/home at=/items/2',
      ]);
      // The answer comes late, to a navigation that is over.
      answer.complete(null);
      await tester.pumpAndSettle();
      expect(rec.log.last, '#3 end guard pass async');
    });
  });

  group('guards', () {
    testWidgets('a sync guard that lets it through', (tester) async {
      final r = await boot(tester);
      rec.log.clear();
      r.go('/checkout');
      await tester.pumpAndSettle();
      expect(rec.log, contains('#3 start guard checkout/guard.dart parent=#2'));
      expect(rec.log, contains('#3 end guard pass'));
    });

    testWidgets('a guard that redirects, with where to', (tester) async {
      checkout = () => '/login';
      final r = await boot(tester);
      rec.log.clear();
      r.go('/checkout');
      await tester.pumpAndSettle();
      expect(rec.log, contains('#3 end guard redirect -> /login'));
      expect(
        rec.log.last,
        '#2 end navigate ok route=/login kind=go from=/home redirected at=/login',
      );
    });

    testWidgets('an async guard is parented to the navigation', (tester) async {
      final answer = Completer<String?>();
      checkout = () => answer.future;
      final r = await boot(tester);
      rec.log.clear();
      r.go('/checkout');
      await tester.pump();
      expect(rec.log, [
        '#2 start navigate /checkout',
        '#3 start guard checkout/guard.dart parent=#2',
      ]);
      answer.complete('/login');
      await tester.pumpAndSettle();
      expect(rec.log[2], '#3 end guard redirect async -> /login');
    });

    testWidgets(
      'a guard whose Future fails is an error, and go_router still gets it',
      (tester) async {
        checkout = () => Future<String?>.error(StateError('boom'));
        final r = await boot(tester);
        rec.log.clear();
        Object? uncaught;
        await runZonedGuarded(() async {
          r.go('/checkout');
          await tester.pump(const Duration(milliseconds: 1));
          await tester.pump();
        }, (error, _) => uncaught = error);
        expect(
          rec.log,
          contains('#3 end guard error async error=Bad state: boom'),
        );
        // Only go_router's own report: the side listener adds no unhandled error.
        expect(uncaught, isA<GoException>());
      },
    );

    testWidgets('a guard that did not run for a bad segment is skipped', (
      tester,
    ) async {
      final r = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(path: '/home', builder: (_, _) => page('home')),
          GoRoute(
            path: '/n/:n',
            redirect: (_, state) => traceGuard(
              state,
              'g9@1',
              guardWithParams<({int n})>(
                () => (n: Segment.asInt(state, 'n')),
                (p) => null,
              ),
              telemetry: guardSite,
            ),
            builder: (_, _) => page('n'),
          ),
        ],
      );
      telemetryAttach(r, base: () => '/');
      await pumpRouter(tester, r);
      rec.log.clear();
      r.go('/n/abc');
      await tester.pumpAndSettle();
      expect(rec.log, contains('#3 end guard skipped'));
    });
  });

  group('data', () {
    test('a value, a Future, and a key that is not recorded', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(syncData), 'sync');
      expect(rec.log, [
        '#1 start data items/\$id/data.dart',
        '#1 end data data',
      ]);
      rec.log.clear();
      final sub = c.listen(item(5), (_, _) {});
      await c.read(item(5).future);
      sub.close();
      expect(rec.log, [
        '#2 start data items/\$id/data.dart keyed',
        '#2 end data data async',
      ]);
    });

    test('a Future that fails', () async {
      final c = ProviderContainer(retry: (_, _) => null);
      addTearDown(c.dispose);
      itemData = (id) => throw StateError('no $id');
      c.listen(item(1), (_, _) {}, onError: (_, _) {});
      await expectLater(c.read(item(1).future), throwsA(anything));
      expect(rec.log, [
        '#1 start data items/\$id/data.dart keyed',
        '#1 end data error async error=Bad state: no 1',
      ]);
    });

    test('a provider disposed before its Future settles', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final never = Completer<String>();
      final slow = FutureProvider.autoDispose<String>(
        (ref) => traceData(ref, 'd3', null, never.future, telemetry: dataSite),
      );
      final sub = c.listen(slow, (_, _) {});
      sub.close();
      // The provider is disposed on the next turn of the event loop.
      await Future<void>.delayed(Duration.zero);
      expect(rec.log, [
        '#1 start data items/\$id/data.dart',
        '#1 end data disposed async',
      ]);
    });

    test('a stream ends at once', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final s = StreamProvider.autoDispose<int>(
        (ref) => traceData(
          ref,
          'd4',
          null,
          Stream<int>.value(1),
          telemetry: dataSite,
        ),
      );
      c.listen(s, (_, _) {});
      expect(rec.log, [
        '#1 start data items/\$id/data.dart',
        '#1 end data stream',
      ]);
    });

    testWidgets('a load that shows a page runs under its navigation', (
      tester,
    ) async {
      final r = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(path: '/home', builder: (_, _) => page('home')),
          GoRoute(
            path: '/items/:id',
            builder: (context, s) => Consumer(
              builder: (context, ref, _) {
                ref.watch(item(int.parse(s.pathParameters['id']!)));
                return page('item');
              },
            ),
          ),
        ],
      );
      telemetryAttach(r, base: () => '/');
      await pumpRouter(tester, r);
      rec.log.clear();
      r.go('/items/3');
      await tester.pumpAndSettle();
      expect(
        rec.log,
        contains('#3 start data items/\$id/data.dart keyed parent=#2'),
      );
      expect(rec.log, contains('#3 end data data async'));
    });
  });

  group('actions', () {
    final ActionProvider<String, String> rename =
        actionProvider<String, String>(
          (ref, input) => input.toUpperCase(),
          invalidates: () => const [],
          telemetry: actionSite,
        );
    final ActionProvider<String, String> renameLater =
        actionProvider<String, String>(
          (ref, input) async => input.toUpperCase(),
          invalidates: () => const [],
          telemetry: actionSite,
        );
    final ActionProvider<String, String> fails = actionProvider<String, String>(
      (ref, input) => throw StateError('no'),
      invalidates: () => const [],
      telemetry: actionSite,
    );
    final ActionProvider<String, String> failsLater =
        actionProvider<String, String>(
          (ref, input) async => throw StateError('later'),
          invalidates: () => const [],
          telemetry: actionSite,
        );

    test('a sync action ends at once', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(rename, (_, _) {});
      expect(c.read(rename.notifier).call('a'), 'A');
      expect(rec.log, [
        '#1 start action items/\$id/action.dart#rename',
        '#1 end action ok',
      ]);
    });

    test('an async action ends when its Future settles', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(renameLater, (_, _) {});
      await c.read(renameLater.notifier).call('a');
      expect(rec.log, [
        '#1 start action items/\$id/action.dart#rename',
        '#1 end action ok async',
      ]);
    });

    test('a failure, sync and async', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(fails, (_, _) {});
      c.listen(failsLater, (_, _) {});
      expect(() => c.read(fails.notifier).call('a'), throwsStateError);
      await expectLater(
        Future.value(c.read(failsLater.notifier).call('a')),
        throwsStateError,
      );
      expect(rec.log, [
        '#1 start action items/\$id/action.dart#rename',
        '#1 end action error error=Bad state: no',
        '#2 start action items/\$id/action.dart#rename',
        '#2 end action error async error=Bad state: later',
      ]);
    });
  });

  group('deferred', () {
    testWidgets('a load is a span; a call that joins it starts none', (
      tester,
    ) async {
      final done = Completer<void>();
      final lib = DeferredLibrary(
        () => done.future,
        'shop/page.dart',
        loadsInFakeAsync: true,
        route: '/shop',
      );
      final first = lib.load();
      final second = lib.load();
      expect(rec.log, ['#1 start deferred shop/page.dart route=/shop']);
      done.complete();
      await first;
      await second;
      expect(rec.log.last, '#1 end deferred ok async');
      expect(rec.log, hasLength(2));
      // Loaded: no more spans.
      await lib.load();
      expect(rec.log, hasLength(2));
    });

    testWidgets('a failed load, and the retry', (tester) async {
      var fail = true;
      final lib = DeferredLibrary(
        () async {
          if (fail) throw StateError('offline');
        },
        'shop/page.dart',
        loadsInFakeAsync: true,
        route: '/shop',
      );
      await expectLater(lib.load(), throwsStateError);
      fail = false;
      await lib.load();
      expect(rec.log, [
        '#1 start deferred shop/page.dart route=/shop',
        '#1 end deferred error async error=Bad state: offline',
        '#2 start deferred shop/page.dart route=/shop',
        '#2 end deferred ok async',
      ]);
    });

    testWidgets('without a route there is no span at all', (tester) async {
      final lib = DeferredLibrary(
        () async {},
        'shop/page.dart',
        loadsInFakeAsync: true,
      );
      await lib.load();
      expect(rec.log, isEmpty);
    });
  });

  group('the sink', () {
    testWidgets('one that throws is caught, and printed once', (tester) async {
      FespalierTelemetry.install(_Throwing());
      final printed = <String>[];
      final old = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add('$message');
      try {
        final r = await boot(tester);
        r.go('/items/1');
        await tester.pumpAndSettle();
        expect(find.text('item 1'), findsOneWidget);
      } finally {
        debugPrint = old;
      }
      expect(printed, [
        'fespalier telemetry: Bad state: sink (not shown again)',
      ]);
    });
  });
}

final class _Throwing extends FespalierTelemetry {
  @override
  Object? start(TelemetryStart start) => throw StateError('sink');

  @override
  void end(Object? token, TelemetryEnd end) => throw StateError('sink');

  @override
  void page(Object? navigation, TelemetryPage page) => throw StateError('sink');
}
