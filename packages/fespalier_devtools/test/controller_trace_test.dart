// FespalierController and the guards, data and actions: what it merges from their events, when it
// asks the app again, and what Invalidate and Open do.

import 'package:fespalier_devtools/src/client.dart';
import 'package:fespalier_devtools/src/controller.dart';
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'trace_fixtures.dart';

Future<FespalierController> started(
  FakeFespalierClient client, {
  DateTime Function()? clock,
}) async {
  final controller = FespalierController(client, clock: clock ?? DateTime.now);
  addTearDown(controller.dispose);
  await pumpEventQueue();
  return controller;
}

List<String> methods(FakeFespalierClient client) => [
  for (final c in client.calls) c.$1,
];

void main() {
  group('features', () {
    test('supports what the app lists', () async {
      final controller = await started(FakeFespalierClient());
      for (final f in allFeatures) {
        expect(controller.supports(f), isTrue, reason: f);
      }
    });

    test('an app of the first release supports none of the new ones', () async {
      final controller = await started(
        FakeFespalierClient(features: firstFeatures),
      );
      expect(controller.supports(DevToolsFeatures.navigate), isTrue);
      expect(controller.supports(DevToolsFeatures.guards), isFalse);
      expect(controller.supports(DevToolsFeatures.data), isFalse);
      expect(controller.supports(DevToolsFeatures.actions), isFalse);
      expect(controller.supports(DevToolsFeatures.open), isFalse);
      // Its snapshot has none of the lists, and is read.
      expect(controller.snapshot!.guards, isEmpty);
    });

    test('supports nothing before the app answered', () {
      final controller = FespalierController(FakeFespalierClient());
      addTearDown(controller.dispose);
      expect(controller.supports(DevToolsFeatures.guards), isFalse);
    });
  });

  group('merging events', () {
    test(
      'a guard event that is next in line is merged without a call',
      () async {
        final client = FakeFespalierClient(
          snapshot: tracedSnapshot(guards: [guardRecord(1)]),
        );
        final controller = await started(client);
        client.calls.clear();
        client.emit(
          DevToolsEvents.guard,
          recordEvent(8, guardRecord(2, uri: '/inbox').toJson()),
        );
        await pumpEventQueue();
        expect(client.calls, isEmpty);
        expect([for (final g in controller.snapshot!.guards) g.seq], [1, 2]);
        expect(controller.snapshot!.event, 8);
      },
    );

    test('a record with a seq it has replaces that one, in place', () async {
      final client = FakeFespalierClient(
        snapshot: tracedSnapshot(
          guards: [
            guardRecord(1),
            guardRecord(2, result: GuardOutcome.pending, isAsync: true),
            guardRecord(3),
          ],
        ),
      );
      final controller = await started(client);
      client.emit(
        DevToolsEvents.guard,
        recordEvent(
          8,
          guardRecord(
            2,
            result: GuardOutcome.redirect,
            location: '/login',
            isAsync: true,
            ms: 30,
          ).toJson(),
        ),
      );
      await pumpEventQueue();
      final guards = controller.snapshot!.guards;
      expect([for (final g in guards) g.seq], [1, 2, 3]);
      expect(guards[1].result, GuardOutcome.redirect);
      expect(guards[1].ms, 30);
    });

    test('data events merge by id, and an update replaces in place', () async {
      final client = FakeFespalierClient(
        snapshot: tracedSnapshot(
          data: [dataRecord(1, state: DataState.loading, value: null)],
        ),
      );
      final controller = await started(client);
      client.emit(
        DevToolsEvents.data,
        recordEvent(8, dataRecord(1, builds: 1).toJson()),
      );
      client.emit(
        DevToolsEvents.data,
        recordEvent(9, dataRecord(2, site: 'd62').toJson()),
      );
      await pumpEventQueue();
      final data = controller.snapshot!.data;
      expect([for (final d in data) d.id], [1, 2]);
      expect(data.first.state, DataState.data);
      expect(controller.snapshot!.event, 9);
    });

    test('action events merge by seq', () async {
      final client = FakeFespalierClient(
        snapshot: tracedSnapshot(
          actions: [
            actionRecord(1, state: ActionState.running, ms: null, result: null),
          ],
        ),
      );
      final controller = await started(client);
      client.emit(
        DevToolsEvents.action,
        recordEvent(8, actionRecord(1).toJson()),
      );
      await pumpEventQueue();
      expect(controller.snapshot!.actions.single.state, ActionState.done);
      expect(controller.snapshot!.actions.single.ms, 120);
    });

    test('an event the snapshot has already is ignored', () async {
      final client = FakeFespalierClient(
        snapshot: tracedSnapshot(guards: [guardRecord(1)]),
      );
      final controller = await started(client);
      client.calls.clear();
      client.emit(
        DevToolsEvents.guard,
        recordEvent(7, guardRecord(9).toJson()),
      );
      await pumpEventQueue();
      expect(client.calls, isEmpty);
      expect(controller.snapshot!.guards, hasLength(1));
    });

    test('an event after a gap fetches the snapshot again', () async {
      final client = FakeFespalierClient(snapshot: tracedSnapshot());
      final controller = await started(client);
      client.calls.clear();
      client.snapshot = tracedSnapshot(
        event: 12,
        guards: [guardRecord(5), guardRecord(6)],
      );
      // The snapshot was at 7; this is 12, so 8 to 11 were missed.
      client.emit(
        DevToolsEvents.guard,
        recordEvent(12, guardRecord(6).toJson()),
      );
      await pumpEventQueue();
      expect(methods(client), contains(DevToolsMethods.snapshot));
      expect(controller.snapshot!.event, 12);
      expect(controller.snapshot!.guards, hasLength(2));
    });

    test('a record it cannot read fetches the snapshot again', () async {
      final client = FakeFespalierClient(snapshot: tracedSnapshot());
      await started(client);
      client.calls.clear();
      client.emit(
        DevToolsEvents.guard,
        recordEvent(8, {'seq': 'not a number'}),
      );
      await pumpEventQueue();
      expect(methods(client), contains(DevToolsMethods.snapshot));
    });

    test('an event without a record fetches the snapshot again', () async {
      final client = FakeFespalierClient(snapshot: tracedSnapshot());
      await started(client);
      client.calls.clear();
      client.emit(DevToolsEvents.data, {'protocol': 1, 'event': 8});
      await pumpEventQueue();
      expect(methods(client), contains(DevToolsMethods.snapshot));
    });

    test(
      'keeps the last $guardLimit guards and $actionLimit actions',
      () async {
        final client = FakeFespalierClient(snapshot: tracedSnapshot());
        final controller = await started(client);
        var n = 8;
        for (var i = 1; i <= guardLimit + 5; i++) {
          client.emit(
            DevToolsEvents.guard,
            recordEvent(n++, guardRecord(i).toJson()),
          );
        }
        for (var i = 1; i <= actionLimit + 5; i++) {
          client.emit(
            DevToolsEvents.action,
            recordEvent(n++, actionRecord(1000 + i).toJson()),
          );
        }
        await pumpEventQueue();
        expect(controller.snapshot!.guards, hasLength(guardLimit));
        expect(controller.snapshot!.guards.first.seq, 6);
        expect(controller.snapshot!.actions, hasLength(actionLimit));
        expect(controller.snapshot!.actions.first.seq, 1006);
      },
    );

    test(
      'keeps the last $disposedLimit disposed records and every live one',
      () async {
        final client = FakeFespalierClient(snapshot: tracedSnapshot());
        final controller = await started(client);
        var n = 8;
        client.emit(
          DevToolsEvents.data,
          recordEvent(n++, dataRecord(1000).toJson()),
        );
        for (var i = 1; i <= disposedLimit + 3; i++) {
          client.emit(
            DevToolsEvents.data,
            recordEvent(n++, dataRecord(i, state: DataState.disposed).toJson()),
          );
        }
        await pumpEventQueue();
        final data = controller.snapshot!.data;
        expect(
          data.where((d) => d.state == DataState.disposed),
          hasLength(disposedLimit),
        );
        expect(data.where((d) => d.id == 1000), hasLength(1));
        expect(data.any((d) => d.id == 1), isFalse);
        expect(data.any((d) => d.id == disposedLimit + 3), isTrue);
      },
    );

    test('tells its listeners, and starts no timer', () async {
      final client = FakeFespalierClient(snapshot: tracedSnapshot());
      final controller = await started(client);
      var told = 0;
      controller.addListener(() => told++);
      client.emit(
        DevToolsEvents.action,
        recordEvent(8, actionRecord(1).toJson()),
      );
      await pumpEventQueue();
      expect(told, 1);
    });

    test('is not merged into a snapshot that is not there yet', () async {
      final client = FakeFespalierClient(snapshot: tracedSnapshot());
      client.connected.value = false;
      final controller = await started(client);
      client.emit(
        DevToolsEvents.guard,
        recordEvent(8, guardRecord(1).toJson()),
      );
      await pumpEventQueue();
      expect(controller.snapshot, isNull);
    });
  });

  group('the age of a record', () {
    test('is counted to the moment the state was fetched', () async {
      var now = DateTime.fromMillisecondsSinceEpoch(1696230100000);
      final client = FakeFespalierClient(snapshot: tracedSnapshot());
      final controller = await started(client, clock: () => now);
      expect(controller.refreshedAt, now);
      now = DateTime.fromMillisecondsSinceEpoch(1696230200000);
      client.emit(
        DevToolsEvents.guard,
        recordEvent(8, guardRecord(1).toJson()),
      );
      await pumpEventQueue();
      expect(controller.refreshedAt, now);
    });
  });

  group('invalidate', () {
    test('asks the app to build the provider again', () async {
      final client = FakeFespalierClient();
      final controller = await started(client);
      await controller.invalidate(7);
      expect(client.callsTo(DevToolsMethods.invalidate), [
        {'id': '7'},
      ]);
      expect(controller.actionError, isNull);
    });

    test('says so when the provider is gone', () async {
      final client = FakeFespalierClient(
        handlers: {
          DevToolsMethods.invalidate: (_) => {'protocol': 1, 'ok': false},
        },
      );
      final controller = await started(client);
      await controller.invalidate(7);
      expect(controller.actionError, contains('not alive any more'));
    });

    test('says what the app said when it refuses', () async {
      final client = FakeFespalierClient(
        handlers: {
          DevToolsMethods.invalidate: (_) =>
              throw const FespalierError('parameter `id` is not a number'),
        },
      );
      final controller = await started(client);
      await controller.invalidate(7);
      expect(controller.actionError, 'parameter `id` is not a number');
    });
  });

  group('holders (since 0.8.0)', () {
    const answer = HoldersRecord(
      id: 7,
      found: true,
      alive: true,
      listeners: 2,
      others: 1,
      holders: [HolderRecord(kind: HolderKind.view, since: 1)],
    );

    test('asks the app who holds the provider, and gives the answer', () async {
      final client = FakeFespalierClient(
        handlers: {DevToolsMethods.holders: (_) => answer.toJson()},
      );
      final controller = await started(client);
      expect(await controller.holders(7), answer);
      expect(client.callsTo(DevToolsMethods.holders), [
        {'id': '7'},
      ]);
      expect(controller.actionError, isNull);
    });

    test('an app that does not list the feature is not asked', () async {
      final client = FakeFespalierClient(features: firstFeatures);
      final controller = await started(client);
      expect(await controller.holders(7), isNull);
      expect(client.callsTo(DevToolsMethods.holders), isEmpty);
    });

    test('says what the app said when it refuses', () async {
      final client = FakeFespalierClient(
        handlers: {
          DevToolsMethods.holders: (_) =>
              throw const FespalierError('parameter `id` is not a number'),
        },
      );
      final controller = await started(client);
      expect(await controller.holders(7), isNull);
      expect(controller.actionError, 'parameter `id` is not a number');
    });

    test('an unknown id is an answer, not an error', () async {
      final client = FakeFespalierClient(
        handlers: {
          DevToolsMethods.holders: (_) =>
              const HoldersRecord(id: 9, found: false).toJson(),
        },
      );
      final controller = await started(client);
      final unknown = await controller.holders(9);
      expect(unknown!.found, isFalse);
      expect(controller.actionError, isNull);
    });
  });

  group('open', () {
    test('asks the app to open a file of the tree', () async {
      final client = FakeFespalierClient();
      final controller = await started(client);
      await controller.open(r'orders/$id/page.dart');
      expect(client.callsTo(DevToolsMethods.open), [
        {'file': r'orders/$id/page.dart'},
      ]);
      expect(controller.actionError, isNull);
    });

    test('says what the app said when it refuses', () async {
      final client = FakeFespalierClient(
        handlers: {
          DevToolsMethods.open: (_) => throw const FespalierError(
            '`x.dart` is not a file of the route tree',
          ),
        },
      );
      final controller = await started(client);
      await controller.open('x.dart');
      expect(controller.actionError, contains('not a file of the route tree'));
    });
  });

  test('clear guards and clear actions ask the app, then fetch', () async {
    final client = FakeFespalierClient();
    final controller = await started(client);
    client.calls.clear();
    await controller.clear(ClearWhat.guards);
    await controller.clear(ClearWhat.actions);
    expect(client.callsTo(DevToolsMethods.clear), [
      {'what': 'guards'},
      {'what': 'actions'},
    ]);
    expect(
      methods(client).where((m) => m == DevToolsMethods.snapshot),
      hasLength(2),
    );
  });
}
