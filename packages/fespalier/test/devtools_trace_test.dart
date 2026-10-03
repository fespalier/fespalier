// What the DevTools extension sees of the guards, the data and the actions (since 0.7.0): the
// wrappers the generated `app.g.dart` puts around them, and what they must not change.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/persist.dart' show StorageOptions;
import 'package:fespalier/src/devtools/devtools.dart'
    show
        debugDevToolsCall,
        debugDevToolsEvents,
        debugDevToolsReset,
        debugDevToolsToolEvents;
import 'package:fespalier/src/devtools/protocol.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _tree = {
  'protocol': 1,
  'package': 'shop',
  'appDir': 'lib/app',
  'items': [
    {
      'type': 'route',
      'file': 'products/\$id/page.dart',
      'children': <Object?>[],
    },
  ],
  'sites': {
    'g1@2': {'kind': 'guard', 'file': '(account)/guard.dart'},
    'd7': {'kind': 'data', 'file': 'products/\$id/data.dart'},
  },
};

String tree() => jsonEncode(_tree);

UrlMatch? matchUrl(Uri uri) => null;

List<(String, Map<String, Object?>)> get events => debugDevToolsEvents!;

Future<SnapshotRecord> snapshot() async =>
    SnapshotRecord.fromJson(await debugDevToolsCall(DevToolsMethods.snapshot));

List<GuardRecord> guardEvents() => [
  for (final (kind, payload) in events)
    if (kind == DevToolsEvents.guard)
      GuardRecord.fromJson(
        payload[DevToolsEventPayload.record]! as Map<String, Object?>,
      ),
];

List<DataRecord> dataEvents() => [
  for (final (kind, payload) in events)
    if (kind == DevToolsEvents.data)
      DataRecord.fromJson(
        payload[DevToolsEventPayload.record]! as Map<String, Object?>,
      ),
];

/// The states the data events went through, with the events that only changed the listeners
/// (a view or a handle came or went) left out: the same state and build in a row is one.
List<(String, int)> dataStates() {
  final out = <(String, int)>[];
  for (final d in dataEvents()) {
    final step = (d.state, d.builds);
    if (out.isEmpty || out.last != step) out.add(step);
  }
  return out;
}

List<ActionRecord> actionEvents() => [
  for (final (kind, payload) in events)
    if (kind == DevToolsEvents.action)
      ActionRecord.fromJson(
        payload[DevToolsEventPayload.record]! as Map<String, Object?>,
      ),
];

Widget page(String label) => Text(label);

/// How many microtasks [body] schedules in its own zone.
int microtasksIn(void Function() body) {
  var count = 0;
  runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      scheduleMicrotask: (self, parent, zone, f) {
        count++;
        parent.scheduleMicrotask(zone, f);
      },
    ),
  );
  return count;
}

void main() {
  setUp(() {
    debugDevToolsReset();
    debugDevToolsEvents = [];
    debugDevToolsToolEvents = [];
  });
  tearDown(() {
    debugDevToolsReset();
    debugDevToolsEvents = null;
    debugDevToolsToolEvents = null;
  });

  test(
    'hello lists the features of the guards, data, actions and open',
    () async {
      final hello = HelloRecord.fromJson(
        await debugDevToolsCall(DevToolsMethods.hello),
      );
      expect(
        hello.features,
        containsAll([
          DevToolsFeatures.guards,
          DevToolsFeatures.data,
          DevToolsFeatures.actions,
          DevToolsFeatures.open,
        ]),
      );
      // Protocol 1 still: the first three are what an extension of the first release asked for.
      expect(hello.features.take(3), [
        DevToolsFeatures.navigation,
        DevToolsFeatures.match,
        DevToolsFeatures.navigate,
      ]);
      expect(hello.protocol, 1);
    },
  );

  group('guards', () {
    late Completer<String?> slow;
    late List<Object> seen;

    GoRouter router({String initial = '/'}) {
      slow = Completer<String?>();
      seen = [];
      return GoRouter(
        initialLocation: initial,
        routes: [
          GoRoute(path: '/', builder: (_, _) => page('HOME')),
          GoRoute(
            path: '/open',
            redirect: (context, state) => traceGuard(state, 'g1@2', null),
            builder: (_, _) => page('OPEN'),
          ),
          GoRoute(
            path: '/admin',
            redirect: (context, state) => firstRedirect([
              () => traceGuard(state, 'g1@2', '/login?from=%2Fadmin'),
              () => traceGuard(state, 'g9@9', null),
            ]),
            builder: (_, _) => page('ADMIN'),
          ),
          GoRoute(
            path: '/many/:i',
            redirect: (context, state) => traceGuard(state, 'g7@8', null),
            builder: (_, _) => page('MANY'),
          ),
          GoRoute(
            path: '/login',
            redirect: (context, state) => traceGuard(state, 'g3@4', null),
            builder: (_, _) => page('LOGIN'),
          ),
          GoRoute(
            path: '/slow',
            redirect: (context, state) =>
                traceGuard(state, 'g4@5', slow.future),
            builder: (_, _) => page('SLOW'),
          ),
          GoRoute(
            path: '/p/:n',
            redirect: (context, state) => traceGuard(
              state,
              'g6@7',
              guardWithParams<int>(
                () => throw const BadSegment('n', 'x', 'int'),
                (n) => '/never',
              ),
            ),
            builder: (_, _) => page('P'),
          ),
          GoRoute(
            path: '/identity',
            redirect: (context, state) {
              final future = Future<String?>.value();
              seen
                ..add(identical(traceGuard(state, 's', future), future))
                ..add(identical(traceGuard(state, 's', '/x'), '/x'))
                ..add(identical(traceGuard(state, 's', null), null))
                ..add(traceGuard(state, 's', null) is! Future);
              return null;
            },
            builder: (_, _) => page('IDENTITY'),
          ),
        ],
      );
    }

    testWidgets('a guard that lets the navigation through is a pass', (
      tester,
    ) async {
      final r = router();
      devToolsAttach(r);
      await pumpRouter(tester, r);
      r.go('/open');
      await tester.pumpAndSettle();
      expect(find.text('OPEN'), findsOneWidget);
      final records = (await snapshot()).guards;
      expect(records, hasLength(1));
      expect(records.single.site, 'g1@2');
      expect(records.single.result, GuardOutcome.pass);
      expect(records.single.uri, '/open');
      expect(records.single.fullPath, '/open');
      expect(records.single.isAsync, isFalse);
      expect(records.single.ms, 0);
      expect(records.single.location, isNull);
    });

    testWidgets('a redirect chain is one navigation with both decisions', (
      tester,
    ) async {
      final r = router();
      devToolsAttach(r);
      await pumpRouter(tester, r);
      r.go('/admin');
      await tester.pumpAndSettle();
      expect(find.text('LOGIN'), findsOneWidget);
      final snap = await snapshot();
      expect(
        [for (final g in snap.guards) (g.site, g.result, g.location)],
        [
          ('g1@2', GuardOutcome.redirect, '/login?from=%2Fadmin'),
          ('g3@4', GuardOutcome.pass, null),
        ],
      );
      final nav = snap.history.last;
      expect(nav.guards, [for (final g in snap.guards) g.seq]);
      expect(nav.uri, '/login?from=%2Fadmin');
      // The first navigation (initial) had no guard.
      expect(snap.history.first.guards, isEmpty);
    });

    testWidgets('an asynchronous guard is pending, then settles in place', (
      tester,
    ) async {
      final r = router();
      devToolsAttach(r);
      await pumpRouter(tester, r);
      r.go('/slow');
      await tester.pump();
      var records = (await snapshot()).guards;
      expect(records.single.result, GuardOutcome.pending);
      expect(records.single.isAsync, isTrue);
      final seq = records.single.seq;
      slow.complete('/login');
      await tester.pumpAndSettle();
      records = (await snapshot()).guards;
      expect(records.first.seq, seq);
      expect(records.first.result, GuardOutcome.redirect);
      expect(records.first.location, '/login');
      expect(records.first.isAsync, isTrue);
      // The same `seq` was sent twice: pending, then the answer.
      final sent = guardEvents().where((g) => g.seq == seq).toList();
      expect(
        [for (final g in sent) g.result],
        [GuardOutcome.pending, GuardOutcome.redirect],
      );
      expect(find.text('LOGIN'), findsOneWidget);
    });

    testWidgets('a guard whose Future fails is an error, and go_router '
        'still gets the failure', (tester) async {
      final failing = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => page('HOME')),
          GoRoute(
            path: '/boom',
            redirect: (context, state) => traceGuard(
              state,
              'g5@6',
              Future<String?>.delayed(
                Duration.zero,
                () => throw StateError('nope'),
              ),
            ),
            builder: (_, _) => page('BOOM'),
          ),
        ],
      );
      devToolsAttach(failing);
      await pumpRouter(tester, failing);
      Object? uncaught;
      await runZonedGuarded(() async {
        failing.go('/boom');
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
      }, (error, _) => uncaught = error);
      final record = (await snapshot()).guards.single;
      expect(record.result, GuardOutcome.error);
      expect(record.error, contains('nope'));
      expect(record.isAsync, isTrue);
      // go_router saw the failure, as it does without DevTools, and it is the only one: the
      // side `then` has an `onError` of its own, so it adds no unhandled error.
      expect(uncaught, isA<GoException>());
      expect('$uncaught', contains('nope'));
      expect(find.text('BOOM'), findsNothing);
    });

    testWidgets('a guard whose segments do not parse is skipped', (
      tester,
    ) async {
      final r = router();
      devToolsAttach(r);
      await pumpRouter(tester, r);
      r.go('/p/x');
      await tester.pumpAndSettle();
      final record = (await snapshot()).guards.single;
      expect(record.result, GuardOutcome.skipped);
      expect(record.site, 'g6@7');
      // The flag is read and cleared: the next guard is a pass again.
      r.go('/open');
      await tester.pumpAndSettle();
      expect((await snapshot()).guards.last.result, GuardOutcome.pass);
    });

    testWidgets('traceGuard returns what it was given, the very object', (
      tester,
    ) async {
      final r = router(initial: '/identity');
      await pumpRouter(tester, r);
      expect(seen, [true, true, true, true]);
    });

    testWidgets('a guard that answers at once schedules no microtask', (
      tester,
    ) async {
      final r = router(initial: '/identity');
      await pumpRouter(tester, r);
      late GoRouterState state;
      final probe = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            redirect: (context, s) {
              state = s;
              return null;
            },
            builder: (_, _) => page('PROBE'),
          ),
        ],
      );
      await pumpRouter(tester, probe);
      expect(microtasksIn(() => traceGuard(state, 'g1@2', null)), 0);
      expect(microtasksIn(() => traceGuard(state, 'g1@2', '/login')), 0);
    });

    testWidgets('clear guards empties them; the counter keeps counting', (
      tester,
    ) async {
      final r = router();
      devToolsAttach(r);
      await pumpRouter(tester, r);
      r.go('/open');
      await tester.pumpAndSettle();
      final before = events.length;
      expect(
        await debugDevToolsCall(DevToolsMethods.clear, {
          'what': ClearWhat.guards,
        }),
        {'protocol': 1, 'ok': true},
      );
      expect((await snapshot()).guards, isEmpty);
      r.go('/open');
      await tester.pumpAndSettle();
      expect((await snapshot()).guards.single.seq, greaterThan(1));
      expect(events.length, greaterThan(before));
    });

    testWidgets('the guards keep the last 200, the newest', (tester) async {
      final r = router();
      devToolsAttach(r);
      await pumpRouter(tester, r);
      for (var i = 0; i < 205; i++) {
        r.go('/many/$i');
        await tester.pump();
      }
      final all = (await snapshot()).guards;
      expect(all, hasLength(200));
      expect(all.last.uri, '/many/204');
      expect(all.first.uri, '/many/5');
    });
  });

  group('data', () {
    ProviderContainer container() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('a Future is loading, then data, with one build', () async {
      final c = container();
      final completer = Completer<String>();
      final provider = FutureProvider.autoDispose<String>(
        (ref) => traceData(ref, 'd7', null, completer.future),
      );
      c.listen(provider, (_, _) {});
      var record = (await snapshot()).data.single;
      expect(record.site, 'd7');
      expect(record.state, DataState.loading);
      expect(record.builds, 1);
      expect(record.key, isNull);
      expect(record.container, 1);
      completer.complete('hello');
      await pumpEventQueue();
      record = (await snapshot()).data.single;
      expect(record.state, DataState.data);
      expect(record.value, const Shown('String', 'hello'));
      expect(record.builds, 1);
      expect(
        [for (final (state, _) in dataStates()) state],
        [DataState.loading, DataState.data],
      );
    });

    test('a Future that fails is an error, and Riverpod gets it too', () async {
      final c = container();
      final provider = FutureProvider.autoDispose<String>(
        (ref) => traceData(
          ref,
          'd7',
          null,
          Future<String>.error(StateError('boom')),
        ),
        retry: (_, _) => null,
      );
      final sub = c.listen(provider, (_, _) {});
      await pumpEventQueue();
      final record = (await snapshot()).data.single;
      expect(record.state, DataState.error);
      expect(record.error, contains('boom'));
      expect(sub.read().hasError, isTrue);
    });

    test('invalidating builds again: two builds, loading in between', () async {
      final c = container();
      var runs = 0;
      final provider = FutureProvider.autoDispose<int>(
        (ref) => traceData(ref, 'd7', null, Future.value(++runs)),
      );
      c.listen(provider, (_, _) {});
      await pumpEventQueue();
      c.invalidate(provider);
      await pumpEventQueue();
      final record = (await snapshot()).data.single;
      expect(record.builds, 2);
      expect(record.state, DataState.data);
      expect(record.value, const Shown('int', '2'));
      expect(dataStates(), [
        (DataState.loading, 1),
        (DataState.data, 1),
        (DataState.disposed, 1),
        (DataState.loading, 2),
        (DataState.data, 2),
      ]);
    });

    test(
      'a provider wrapped in freshData (since 0.8.0) is traced the same',
      () async {
        final c = container();
        var runs = 0;
        final provider = FutureProvider.autoDispose<int>(
          (ref) => freshData(
            ref,
            const Freshness(staleTime: Duration(minutes: 1)),
            traceData(ref, 'd7', null, Future.value(++runs)),
          ),
        );
        c.listen(provider, (_, _) {});
        await pumpEventQueue();
        c.invalidate(provider);
        await pumpEventQueue();
        final record = (await snapshot()).data.single;
        expect(record.builds, 2);
        expect(record.state, DataState.data);
        expect(record.value, const Shown('int', '2'));
      },
    );

    test('and so is a cachedData provider, with a saved value in front of it '
        '(since 0.8.0)', () async {
      final storage = MemoryDataStorage()
        ..write('fespalier:items', '5', const StorageOptions());
      final c = ProviderContainer(
        retry: (_, _) => null,
        overrides: [dataCacheStorage.overrideWithValue(storage)],
      );
      addTearDown(c.dispose);
      var runs = 0;
      final provider = cachedData<int>(
        (ref) => traceData(ref, 'd7', null, Future.value(++runs + 10)),
        cache: DataCache<int>(encode: (v) => '$v', decode: int.parse),
        name: 'items',
      );
      final sub = c.listen(provider, (_, _) {});
      // The saved value is the state, but the data record is of what the function returned.
      expect(sub.read().isFromCache, isTrue);
      await pumpEventQueue();
      final record = (await snapshot()).data.single;
      expect(record.builds, 1);
      expect(record.state, DataState.data);
      expect(record.value, const Shown('int', '11'));
      expect(sub.read().requireValue, 11);
      sub.close();
      await pumpEventQueue();
      expect((await snapshot()).data.single.state, DataState.disposed);
    });

    test('disposal is shown, and a family key is', () async {
      final c = container();
      final provider = FutureProvider.autoDispose.family<String, int>(
        (ref, id) => traceData(ref, 'd7', id, Future.value('item $id')),
      );
      final sub = c.listen(provider(3), (_, _) {});
      await pumpEventQueue();
      var record = (await snapshot()).data.single;
      expect(record.key, const Shown('int', '3'));
      expect(record.state, DataState.data);
      sub.close();
      await pumpEventQueue();
      record = (await snapshot()).data.single;
      expect(record.state, DataState.disposed);
      // Read again: the same record is live again, a second build.
      c.listen(provider(3), (_, _) {});
      await pumpEventQueue();
      record = (await snapshot()).data.single;
      expect(record.state, DataState.data);
      expect(record.builds, 2);
      // Another key is another record.
      c.listen(provider(4), (_, _) {});
      await pumpEventQueue();
      expect((await snapshot()).data.map((d) => d.key!.text), ['3', '4']);
    });

    test(
      'a Future that settles after its provider was disposed changes nothing',
      () async {
        final c = container();
        final completer = Completer<String>();
        final provider = FutureProvider.autoDispose<String>(
          (ref) => traceData(ref, 'd7', null, completer.future),
        );
        final sub = c.listen(provider, (_, _) {});
        await pumpEventQueue();
        sub.close();
        await pumpEventQueue();
        expect((await snapshot()).data.single.state, DataState.disposed);
        final before = dataEvents().length;
        completer.complete('late');
        await pumpEventQueue();
        final record = (await snapshot()).data.single;
        expect(record.state, DataState.disposed);
        expect(record.value, isNull);
        expect(dataEvents(), hasLength(before));
      },
    );

    test('a value body is data at once, and returned as it is', () async {
      final c = container();
      final value = Object();
      Object? returned;
      final provider = Provider.autoDispose<Object>((ref) {
        returned = traceData(ref, 'd7', null, value);
        return returned!;
      });
      c.listen(provider, (_, _) {});
      expect(identical(returned, value), isTrue);
      final record = (await snapshot()).data.single;
      expect(record.state, DataState.data);
      expect(record.value!.type, 'Object');
    });

    test('a Future stays the very Future', () async {
      final c = container();
      final future = Future<int>.value(1);
      Object? returned;
      final provider = FutureProvider.autoDispose<int>((ref) {
        final result = traceData(ref, 'd7', null, future);
        returned = result;
        return result;
      });
      c.listen(provider, (_, _) {});
      expect(identical(returned, future), isTrue);
    });

    test('a data body that is sync schedules no microtask', () {
      final c = container();
      late Ref captured;
      final provider = Provider.autoDispose<int>((ref) {
        captured = ref;
        return 1;
      });
      c.listen(provider, (_, _) {});
      expect(
        microtasksIn(() {
          traceData<int>(captured, 'd7', null, 5);
        }),
        0,
      );
      expect(
        microtasksIn(() {
          traceData<String>(captured, 'd7', 'k', 'v');
        }),
        0,
      );
    });

    test('a Stream is marked, and never listened to', () async {
      final c = container();
      var listened = false;
      final controller = StreamController<int>(onListen: () => listened = true);
      addTearDown(() => unawaited(controller.close()));
      final provider = Provider.autoDispose<Stream<int>>(
        (ref) => traceData(ref, 'd7', null, controller.stream),
      );
      c.listen(provider, (_, _) {});
      await pumpEventQueue();
      expect((await snapshot()).data.single.state, DataState.stream);
      expect(listened, isFalse);
    });

    test('the invalidate handler builds a mounted provider again', () async {
      final c = container();
      var runs = 0;
      final provider = FutureProvider.autoDispose<int>(
        (ref) => traceData(ref, 'd7', null, Future.value(++runs)),
      );
      c.listen(provider, (_, _) {});
      await pumpEventQueue();
      final id = (await snapshot()).data.single.id;
      final answer = await debugDevToolsCall(DevToolsMethods.invalidate, {
        'id': '$id',
      });
      expect(answer, {'protocol': 1, 'ok': true});
      await pumpEventQueue();
      expect(runs, 2);
      expect((await snapshot()).data.single.builds, 2);
    });

    test('invalidate says no for an unknown or a disposed record', () async {
      final c = container();
      expect(
        await debugDevToolsCall(DevToolsMethods.invalidate, {'id': '99'}),
        {'protocol': 1, 'ok': false},
      );
      final provider = FutureProvider.autoDispose<int>(
        (ref) => traceData(ref, 'd7', null, Future.value(1)),
      );
      final sub = c.listen(provider, (_, _) {});
      await pumpEventQueue();
      final id = (await snapshot()).data.single.id;
      sub.close();
      await pumpEventQueue();
      expect(
        await debugDevToolsCall(DevToolsMethods.invalidate, {'id': '$id'}),
        {'protocol': 1, 'ok': false},
      );
      final bad = await debugDevToolsCall(DevToolsMethods.invalidate, {
        'id': 'x',
      });
      expect(bad['errorCode'], isNotNull);
      final missing = await debugDevToolsCall(DevToolsMethods.invalidate);
      expect(missing['errorDetail'], contains('`id`'));
    });

    test('asking reads nothing and listens to nothing: the body runs the same '
        'with and without snapshots', () async {
      Future<int> bodyRuns({required bool ask}) async {
        final c = ProviderContainer();
        var runs = 0;
        final provider = FutureProvider.autoDispose<int>(
          (ref) => traceData(ref, 'd7', null, Future.value(++runs)),
        );
        final sub = c.listen(provider, (_, _) {});
        await pumpEventQueue();
        if (ask) {
          for (var i = 0; i < 3; i++) {
            await debugDevToolsCall(DevToolsMethods.snapshot);
          }
        }
        sub.close();
        await pumpEventQueue();
        if (ask) await debugDevToolsCall(DevToolsMethods.snapshot);
        c.dispose();
        return runs;
      }

      final without = await bodyRuns(ask: false);
      final withAsking = await bodyRuns(ask: true);
      expect(withAsking, without);
      expect(withAsking, 1);
    });

    test('two containers are told apart', () async {
      final a = container();
      final b = container();
      final provider = FutureProvider.autoDispose<int>(
        (ref) => traceData(ref, 'd7', null, Future.value(1)),
      );
      a.listen(provider, (_, _) {});
      b.listen(provider, (_, _) {});
      await pumpEventQueue();
      expect((await snapshot()).data.map((d) => d.container), [1, 2]);
    });

    test('records of disposed providers are limited to 50', () async {
      final c = container();
      final provider = FutureProvider.autoDispose.family<int, int>(
        (ref, id) => traceData(ref, 'd7', id, Future.value(id)),
      );
      for (var i = 0; i < 60; i++) {
        c.listen(provider(i), (_, _) {}).close();
        await pumpEventQueue();
      }
      final all = (await snapshot()).data;
      expect(all.where((d) => d.state == DataState.disposed), hasLength(50));
    });

    test('a text and a key are shown at once, with their types', () async {
      final c = container();
      final provider = Provider.autoDispose<String>(
        (ref) => traceData(ref, 'd7', 7, 'plain'),
      );
      c.listen(provider, (_, _) {});
      final record = (await snapshot()).data.single;
      expect(record.value, const Shown('String', 'plain'));
      expect(record.key, const Shown('int', '7'));
    });

    test('clear all forgets the disposed, not the live', () async {
      final c = container();
      final provider = FutureProvider.autoDispose.family<int, int>(
        (ref, id) => traceData(ref, 'd7', id, Future.value(id)),
      );
      c.listen(provider(1), (_, _) {});
      c.listen(provider(2), (_, _) {}).close();
      await pumpEventQueue();
      await debugDevToolsCall(DevToolsMethods.clear, {'what': ClearWhat.all});
      expect((await snapshot()).data.map((d) => d.key!.text), ['1']);
    });
  });

  group('watchData', () {
    Widget scoped(Widget child) => ProviderScope(
      child: MaterialApp(home: Material(child: child)),
    );

    Widget viewOf(
      ProviderListenable<AsyncValue<String>> provider, {
      bool traced = true,
    }) => DataView<String>(
      watch: (ref) =>
          traced ? watchData(ref, 'd7', provider) : ref.watch(provider),
      refresh: (ref) {},
      data: (d) => Text(d),
      loading: () => const Text('loading'),
      error: (e, st, retry) => const Text('error'),
    );

    testWidgets('ref.watch and watchData return the very same object', (
      tester,
    ) async {
      final provider = Provider.autoDispose<AsyncValue<String>>(
        (ref) => const AsyncData('v'),
      );
      Object? plain;
      Object? wrapped;
      Object? plainSelected;
      Object? wrappedSelected;
      await tester.pumpWidget(
        scoped(
          Consumer(
            builder: (context, ref, _) {
              plain = ref.watch(provider);
              wrapped = watchData(ref, 'd7', provider);
              final selection = provider.select((AsyncValue<String> v) => v);
              plainSelected = ref.watch(selection);
              wrappedSelected = watchData(ref, 'd8', selection);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(identical(plain, wrapped), isTrue);
      expect(identical(plainSelected, wrappedSelected), isTrue);
    });

    testWidgets('a value that is there is shown on the first frame', (
      tester,
    ) async {
      final provider = Provider.autoDispose<AsyncValue<String>>(
        (ref) => const AsyncData('now'),
      );
      await tester.pumpWidget(scoped(viewOf(provider)));
      expect(find.text('now'), findsOneWidget);
      expect(find.text('loading'), findsNothing);
    });

    testWidgets('it schedules no microtask, timer or frame of its own', (
      tester,
    ) async {
      final provider = Provider.autoDispose<AsyncValue<String>>(
        (ref) => const AsyncData('a'),
      );
      Future<(int, int, bool)> run({required bool wrapped}) async {
        var microtasks = -1;
        await tester.pumpWidget(
          scoped(
            Consumer(
              builder: (context, ref, _) {
                microtasks = microtasksIn(
                  () => wrapped
                      ? watchData(ref, 'd7', provider)
                      : ref.watch(provider),
                );
                return const SizedBox();
              },
            ),
          ),
        );
        return (
          microtasks,
          tester.binding.transientCallbackCount,
          tester.binding.hasScheduledFrame,
        );
      }

      // Whatever Riverpod and the app shell schedule, watchData adds nothing to it.
      final plain = await run(wrapped: false);
      await tester.pumpWidget(const SizedBox());
      expect(await run(wrapped: true), plain);
    });

    testWidgets('with traceData it adds no listener: one while shown, none '
        'after, as with ref.watch', (tester) async {
      Future<(int, int)> listeners({required bool traced}) async {
        var adds = 0;
        var removes = 0;
        final provider = FutureProvider.autoDispose<String>((ref) {
          ref.onAddListener(() => adds++);
          ref.onRemoveListener(() => removes++);
          return traceData(ref, 'd7', null, Future.value('x'));
        });
        await tester.pumpWidget(scoped(viewOf(provider, traced: traced)));
        await tester.pump();
        final shown = adds - removes;
        await tester.pumpWidget(scoped(const SizedBox()));
        await tester.pump();
        return (shown, adds - removes);
      }

      expect(await listeners(traced: false), (1, 0));
      expect(await listeners(traced: true), (1, 0));
    });

    testWidgets('a data body that is a sync value stays sync through a view', (
      tester,
    ) async {
      final provider = Provider.autoDispose<AsyncValue<String>>(
        (ref) => AsyncData(traceData(ref, 'd7', null, 'now')),
      );
      await tester.pumpWidget(scoped(viewOf(provider)));
      expect(find.text('now'), findsOneWidget);
    });

    testWidgets(
      'with no app registered it records nothing and breaks nothing',
      (tester) async {
        final provider = FutureProvider.autoDispose<String>(
          (ref) => traceData(ref, 'd7', null, Future.value('x')),
        );
        await tester.pumpWidget(scoped(viewOf(provider)));
        await tester.pump();
        expect(find.text('x'), findsOneWidget);
        expect((await snapshot()).data.single.via, DataVia.build);
      },
    );
  });

  group('actions', () {
    ProviderContainer container() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('a sync success is running, then done', () async {
      final c = container();
      final p = actionProvider<int, int>(
        (ref, input) => input * 2,
        invalidates: () => const [],
        site: 'a7_0',
      );
      expect(c.read(p.notifier).call(21), 42);
      final all = (await snapshot()).actions;
      expect(all, hasLength(1));
      expect(all.single.site, 'a7_0');
      expect(all.single.state, ActionState.done);
      expect(all.single.input, const Shown('int', '21'));
      expect(all.single.result, const Shown('int', '42'));
      expect(all.single.ms, isNotNull);
      expect(all.single.key, isNull);
      expect(
        [for (final a in actionEvents()) a.state],
        [ActionState.running, ActionState.done],
      );
    });

    test('a sync action stays sync: no Future, no microtask of ours', () {
      // Riverpod schedules what it schedules when the state is written; what matters is that
      // tracing adds nothing to it, so the same action with and without a site is compared.
      int run({String? site}) {
        final c = container();
        final p = actionProvider<int, int>(
          (ref, input) => input,
          invalidates: () => const [],
          site: site,
        );
        final notifier = c.read(p.notifier);
        Object? result;
        final count = microtasksIn(() => result = notifier.call(1));
        expect(result, 1);
        return count;
      }

      expect(run(site: 'a7_0'), run());
    });

    test('an async success is running, then done with the time', () async {
      final c = container();
      final completer = Completer<String>();
      final p = actionProvider<String, String>(
        (ref, input) => completer.future,
        invalidates: () => const [],
        site: 'a7_0',
      );
      final run = c.read(p.notifier).call('go');
      var record = (await snapshot()).actions.single;
      expect(record.state, ActionState.running);
      expect(record.ms, isNull);
      expect(record.result, isNull);
      completer.complete('done!');
      await run;
      record = (await snapshot()).actions.single;
      expect(record.state, ActionState.done);
      expect(record.ms, isNotNull);
      expect(record.result, const Shown('String', 'done!'));
    });

    test('an async failure is an error, and still rethrown', () async {
      final c = container();
      final p = actionProvider<int, int>(
        (ref, input) => Future<int>.error(StateError('refused')),
        invalidates: () => const [],
        site: 'a7_0',
      );
      await expectLater(c.read(p.notifier).call(1), throwsStateError);
      final record = (await snapshot()).actions.single;
      expect(record.state, ActionState.error);
      expect(record.error, contains('refused'));
      expect(record.result, isNull);
    });

    test('a sync failure is an error, and still thrown', () async {
      final c = container();
      final p = actionProvider<int, int>(
        (ref, input) => throw StateError('sync refused'),
        invalidates: () => const [],
        site: 'a7_0',
      );
      expect(() => c.read(p.notifier).call(1), throwsStateError);
      final record = (await snapshot()).actions.single;
      expect(record.state, ActionState.error);
      expect(record.error, contains('sync refused'));
    });

    test('a family passes its key, and its site', () async {
      final c = container();
      final p = actionFamily<int, String, String>(
        (ref, key, input) => '$key:$input',
        invalidates: (key) => const [],
        site: 'a8_1',
      );
      c.read(p(5).notifier).call('x');
      final record = (await snapshot()).actions.single;
      expect(record.site, 'a8_1');
      expect(record.key, const Shown('int', '5'));
      expect(record.result, const Shown('String', '5:x'));
    });

    test('an action with no site is not recorded', () async {
      final c = container();
      final p = actionProvider<int, int>(
        (ref, input) => input,
        invalidates: () => const [],
      );
      c.read(p.notifier).call(1);
      expect((await snapshot()).actions, isEmpty);
      expect(actionEvents(), isEmpty);
    });

    test(
      'the runs keep the last 100, and clear actions empties them',
      () async {
        final c = container();
        final p = actionProvider<int, int>(
          (ref, input) => input,
          invalidates: () => const [],
          site: 'a7_0',
        );
        final notifier = c.read(p.notifier);
        for (var i = 0; i < 105; i++) {
          notifier.call(i);
        }
        final all = (await snapshot()).actions;
        expect(all, hasLength(100));
        expect(all.first.input.text, '5');
        await debugDevToolsCall(DevToolsMethods.clear, {
          'what': ClearWhat.actions,
        });
        expect((await snapshot()).actions, isEmpty);
      },
    );

    test('an input held weakly is shown while it lives', () async {
      final c = container();
      final p = actionProvider<_Form, int>(
        (ref, input) => 1,
        invalidates: () => const [],
        site: 'a7_0',
      );
      final form = _Form('ann');
      c.read(p.notifier).call(form);
      expect(
        (await snapshot()).actions.single.input,
        const Shown('_Form', 'Form(ann)'),
      );
      expect(form.name, 'ann');
    });
  });

  group('open', () {
    setUp(() => devToolsRegister(tree: tree, matchUrl: matchUrl));

    test(
      'posts a navigate event on the ToolEvent stream, with a package: URI',
      () async {
        final answer = await debugDevToolsCall(DevToolsMethods.open, {
          'file': r'products/$id/page.dart',
        });
        expect(answer, {'protocol': 1, 'ok': true});
        expect(debugDevToolsToolEvents, [
          {
            'fileUri': r'package:shop/app/products/$id/page.dart',
            'line': 1,
            'column': 1,
            'source': 'fespalier.devtools',
          },
        ]);
      },
    );

    test('opens a file that is only a site\'s', () async {
      await debugDevToolsCall(DevToolsMethods.open, {
        'file': '(account)/guard.dart',
      });
      expect(
        debugDevToolsToolEvents!.single['fileUri'],
        'package:shop/app/(account)/guard.dart',
      );
    });

    test('refuses what is not a file of the tree', () async {
      for (final file in ['../main.dart', '/etc/passwd', 'nope.dart']) {
        final answer = await debugDevToolsCall(DevToolsMethods.open, {
          'file': file,
        });
        expect(answer['errorDetail'], contains('not a file of the route tree'));
      }
      expect(debugDevToolsToolEvents, isEmpty);
      final missing = await debugDevToolsCall(DevToolsMethods.open);
      expect(missing['errorDetail'], contains('`file`'));
    });

    test(
      'says so when the app has no tree, or the folder is not under lib/',
      () async {
        debugDevToolsReset();
        var answer = await debugDevToolsCall(DevToolsMethods.open, {
          'file': 'a.dart',
        });
        expect(answer['errorDetail'], 'no fespalier app registered');
        devToolsRegister(
          tree: () => jsonEncode({
            'protocol': 1,
            'package': 'shop',
            'appDir': 'app',
            'items': [
              {'type': 'route', 'file': 'a.dart'},
            ],
          }),
          matchUrl: matchUrl,
        );
        answer = await debugDevToolsCall(DevToolsMethods.open, {
          'file': 'a.dart',
        });
        expect(answer['errorDetail'], contains('under lib/'));
      },
    );
  });

  group('the snapshot and the events', () {
    test('every payload survives jsonEncode', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final data = FutureProvider.autoDispose<_Form>(
        (ref) => traceData(ref, 'd7', _Form('ann'), Future.value(_Form('bo'))),
      );
      final action = actionProvider<_Form, _Form>(
        (ref, input) => input,
        invalidates: () => const [],
        site: 'a7_0',
      );
      c.listen(data, (_, _) {});
      c.read(action.notifier).call(_Form('cy'));
      await pumpEventQueue();
      for (final (_, payload) in events) {
        expect(() => jsonEncode(payload), returnsNormally);
      }
      final raw = await debugDevToolsCall(DevToolsMethods.snapshot);
      expect(() => jsonEncode(raw), returnsNormally);
      final snap = await snapshot();
      expect(snap.data.single.key, const Shown('_Form', 'Form(ann)'));
      expect(snap.data.single.value, const Shown('_Form', 'Form(bo)'));
    });

    test('with no spy and no tool listening nothing throws', () async {
      debugDevToolsEvents = null;
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final data = FutureProvider.autoDispose<int>(
        (ref) => traceData(ref, 'd7', null, Future.value(1)),
      );
      c.listen(data, (_, _) {});
      await pumpEventQueue();
      expect((await snapshot()).data, hasLength(1));
    });

    test(
      'event numbers count the guards, the data and the actions too',
      () async {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final action = actionProvider<int, int>(
          (ref, input) => input,
          invalidates: () => const [],
          site: 'a7_0',
        );
        c.read(action.notifier).call(1);
        final numbers = [
          for (final (_, payload) in events)
            payload[DevToolsEventPayload.event]! as int,
        ];
        expect(numbers, [1, 2]);
      },
    );
  });
}

final class _Form {
  _Form(this.name);
  final String name;

  @override
  String toString() => 'Form($name)';
}
