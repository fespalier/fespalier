// FespalierController, against a scripted app.
import 'dart:async';

import 'package:fespalier_devtools/src/client.dart';
import 'package:fespalier_devtools/src/controller.dart';
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';

Future<FespalierController> started(FakeFespalierClient client) async {
  final controller = FespalierController(client);
  addTearDown(controller.dispose);
  await pumpEventQueue();
  return controller;
}

List<String> methods(FakeFespalierClient client) => [
  for (final c in client.calls) c.$1,
];

NavigationRecord record(int seq, String uri) => NavigationRecord(
  seq: seq,
  at: 1696230000000 + seq,
  kind: NavigationKind.go,
  uri: uri,
  fullPath: uri,
  depth: 0,
);

void main() {
  test('loads hello, the tree and a snapshot at the start', () async {
    final client = FakeFespalierClient();
    final controller = await started(client);
    expect(methods(client), [
      DevToolsMethods.hello,
      DevToolsMethods.tree,
      DevToolsMethods.snapshot,
    ]);
    expect(controller.status, FespalierStatus.ready);
    expect(controller.hello!.features, contains(DevToolsFeatures.navigate));
    expect(controller.tree!.package, 'features');
    expect(controller.snapshot!.location!.uri, '/catalog/p1/reviews?page=2');
  });

  test('finds the route the router is at, by class', () async {
    final controller = await started(FakeFespalierClient());
    expect(controller.currentRoute!.route, 'ReviewsRoute');
  });

  test(
    'finds it by path template when the class is not a name in the tree',
    () async {
      final snapshot = fixture('snapshot_catalog');
      final location = Map<String, Object?>.of(
        snapshot['location']! as Map<String, Object?>,
      )..['route'] = 'Rq';
      final controller = await started(
        FakeFespalierClient(snapshot: {...snapshot, 'location': location}),
      );
      expect(controller.currentRoute!.route, 'ReviewsRoute');
    },
  );

  group('status', () {
    test('is waiting while DevTools is not connected', () async {
      final client = FakeFespalierClient();
      client.connected.value = false;
      final controller = await started(client);
      expect(controller.status, FespalierStatus.waiting);
      expect(client.calls, isEmpty);
    });

    test('is unsupported when the app has no fespalier extension', () async {
      final client = FakeFespalierClient();
      client.hasFespalier.value = false;
      final controller = await started(client);
      expect(controller.status, FespalierStatus.unsupported);
      expect(client.calls, isEmpty);
    });

    test(
      'loads when the extension appears, and when the connection does',
      () async {
        final client = FakeFespalierClient();
        client.connected.value = false;
        client.hasFespalier.value = false;
        final controller = await started(client);
        client.connected.value = true;
        await pumpEventQueue();
        expect(controller.status, FespalierStatus.unsupported);
        client.hasFespalier.value = true;
        await pumpEventQueue();
        expect(controller.status, FespalierStatus.ready);
      },
    );

    test('is a mismatch when the app speaks another protocol', () async {
      final client = FakeFespalierClient(protocol: 2);
      final controller = await started(client);
      expect(controller.status, FespalierStatus.mismatch);
      expect(controller.statusDetail, '2');
      expect(methods(client), [DevToolsMethods.hello]);
    });

    test('is notMounted when the app has not mounted its routes', () async {
      final controller = await started(FakeFespalierClient(registered: false));
      expect(controller.status, FespalierStatus.notMounted);
    });

    test(
      'is noRouter when nothing is attached, and still has the tree',
      () async {
        final controller = await started(
          FakeFespalierClient(
            attached: false,
            snapshot: {
              ...fixture('snapshot_catalog'),
              'attached': false,
              'location': null,
              'stack': <Object?>[],
            },
          ),
        );
        expect(controller.status, FespalierStatus.noRouter);
        expect(controller.tree, isNotNull);
        expect(controller.snapshot!.location, isNull);
      },
    );

    test(
      'is failed, with the error, when a call fails; refresh recovers',
      () async {
        var failing = true;
        final client = FakeFespalierClient(
          handlers: {
            DevToolsMethods.snapshot: (_) {
              if (failing) throw const FespalierError('boom', code: -32000);
              return fixture('snapshot_catalog');
            },
          },
        );
        final controller = await started(client);
        expect(controller.status, FespalierStatus.failed);
        expect(controller.statusDetail, 'boom');
        failing = false;
        await controller.refresh();
        expect(controller.status, FespalierStatus.ready);
        expect(controller.statusDetail, isNull);
      },
    );
  });

  group('events', () {
    test('a navigation fetches the snapshot, and not the tree', () async {
      final client = FakeFespalierClient();
      final controller = await started(client);
      client.calls.clear();
      client.snapshot = {
        ...fixture('snapshot_catalog'),
        'event': 8,
        'history': [record(4, '/other').toJson()],
      };
      client.emit(
        DevToolsEvents.navigation,
        navigationEvent(8, record(4, '/other')),
      );
      await pumpEventQueue();
      expect(methods(client), [
        DevToolsMethods.hello,
        DevToolsMethods.snapshot,
      ]);
      expect(controller.snapshot!.history.single.uri, '/other');
    });

    test('an event the snapshot already has is ignored', () async {
      final client = FakeFespalierClient();
      await started(client);
      client.calls.clear();
      client.emit(
        DevToolsEvents.navigation,
        navigationEvent(7, record(3, '/')),
      );
      client.emit(
        DevToolsEvents.navigation,
        navigationEvent(5, record(2, '/')),
      );
      await pumpEventQueue();
      expect(client.calls, isEmpty);
    });

    test('an event after a gap fetches the snapshot again', () async {
      final client = FakeFespalierClient();
      final controller = await started(client);
      client.calls.clear();
      // The snapshot was at event 7; this is event 12, so some were missed.
      client.snapshot = {...fixture('snapshot_catalog'), 'event': 12};
      client.emit(
        DevToolsEvents.navigation,
        navigationEvent(12, record(9, '/x')),
      );
      await pumpEventQueue();
      expect(methods(client), contains(DevToolsMethods.snapshot));
      expect(controller.snapshot!.event, 12);
    });

    test('registered fetches the tree again', () async {
      final client = FakeFespalierClient();
      await started(client);
      client.calls.clear();
      client.emit(DevToolsEvents.registered, {'protocol': 1, 'event': 9});
      await pumpEventQueue();
      expect(methods(client), [
        DevToolsMethods.hello,
        DevToolsMethods.tree,
        DevToolsMethods.snapshot,
      ]);
    });

    test('a burst of events costs two loads at most', () async {
      // The app is slow to answer the second snapshot: the events come in meanwhile.
      final gate = Completer<void>();
      var snapshots = 0;
      final client = FakeFespalierClient(
        handlers: {
          DevToolsMethods.snapshot: (_) async {
            if (++snapshots == 2) await gate.future;
            return fixture('snapshot_catalog');
          },
        },
      );
      await started(client);
      expect(snapshots, 1);
      client.emit(
        DevToolsEvents.navigation,
        navigationEvent(8, record(4, '/n8')),
      );
      await pumpEventQueue();
      for (var n = 9; n < 28; n++) {
        client.emit(
          DevToolsEvents.navigation,
          navigationEvent(n, record(n, '/n$n')),
        );
      }
      await pumpEventQueue();
      gate.complete();
      await pumpEventQueue();
      // The first at the start, the one the gate held, and one more for everything since.
      expect(snapshots, 3);
    });

    test('an event of a kind it does not know is ignored', () async {
      final client = FakeFespalierClient();
      await started(client);
      client.calls.clear();
      client.emit('fespalier:guard', {'protocol': 1, 'event': 20});
      await pumpEventQueue();
      expect(client.calls, isEmpty);
    });
  });

  test('a restart forgets what was fetched, and loads it again', () async {
    final client = FakeFespalierClient();
    final controller = await started(client);
    client.calls.clear();
    client.snapshot = fixture('snapshot_pushed');
    client.restart();
    expect(controller.status, FespalierStatus.waiting);
    expect(controller.snapshot, isNull);
    expect(controller.tree, isNull);
    await pumpEventQueue();
    expect(controller.status, FespalierStatus.ready);
    expect(controller.snapshot!.location!.uri, '/orders/5');
    expect(controller.tree, isNotNull);
  });

  test(
    'refresh fetches the tree too: a hot reload changes it and says nothing',
    () async {
      final client = FakeFespalierClient();
      final controller = await started(client);
      client.calls.clear();
      await controller.refresh();
      expect(methods(client), [
        DevToolsMethods.hello,
        DevToolsMethods.tree,
        DevToolsMethods.snapshot,
      ]);
      expect(controller.status, FespalierStatus.ready);
    },
  );

  group('navigate', () {
    test('asks the app to go, push or replace', () async {
      final client = FakeFespalierClient();
      final controller = await started(client);
      await controller.navigate(NavigateMode.go, '/products/2');
      await controller.navigate(NavigateMode.push, '/cart');
      await controller.navigate(NavigateMode.replace, '/login');
      expect(client.callsTo(DevToolsMethods.navigate), [
        {'mode': 'go', 'location': '/products/2'},
        {'mode': 'push', 'location': '/cart'},
        {'mode': 'replace', 'location': '/login'},
      ]);
      expect(controller.actionError, isNull);
    });

    test('pop sends no location', () async {
      final client = FakeFespalierClient();
      final controller = await started(client);
      await controller.navigate(NavigateMode.pop, '/ignored');
      expect(client.callsTo(DevToolsMethods.navigate), [
        {'mode': 'pop'},
      ]);
    });

    test('says what the app said when it refuses', () async {
      final client = FakeFespalierClient(
        handlers: {
          DevToolsMethods.navigate: (_) =>
              throw const FespalierError('no fespalier router attached'),
        },
      );
      final controller = await started(client);
      await controller.navigate(NavigateMode.go, '/x');
      expect(controller.actionError, 'no fespalier router attached');
      // The next one that works clears it.
      client.handlers[DevToolsMethods.navigate] = (_) => {'ok': true};
      await controller.navigate(NavigateMode.go, '/x');
      expect(controller.actionError, isNull);
    });
  });

  group('match', () {
    test('keeps the answer and the location it was for', () async {
      final client = FakeFespalierClient(
        handlers: {
          DevToolsMethods.match: (params) => const MatchRecord(
            location: '/products/2',
            route: 'ReviewsRoute',
            params: {'productId': Shown('String', 'p1')},
            data: 2,
          ).toJson(),
        },
      );
      final controller = await started(client);
      await controller.matchLocation('/products/2');
      expect(controller.match!.route, 'ReviewsRoute');
      expect(controller.matchedLocation, '/products/2');
      expect(client.callsTo(DevToolsMethods.match).single, {
        'location': '/products/2',
      });
    });
  });

  group('clear', () {
    test('clears, then fetches the snapshot again', () async {
      final client = FakeFespalierClient();
      final controller = await started(client);
      client.calls.clear();
      await controller.clear(ClearWhat.history);
      expect(client.callsTo(DevToolsMethods.clear).single, {'what': 'history'});
      expect(methods(client), contains(DevToolsMethods.snapshot));
    });
  });

  test(
    'schedules nothing: no timer is pending once the calls are done',
    () async {
      final client = FakeFespalierClient();
      final controller = await started(client);
      // `flutter_test` fails a test that leaves a timer; a burst of work must leave none.
      client.emit(
        DevToolsEvents.navigation,
        navigationEvent(9, record(5, '/y')),
      );
      await controller.navigate(NavigateMode.go, '/y');
      await pumpEventQueue();
    },
  );

  test('stops listening when disposed', () async {
    final client = FakeFespalierClient();
    final controller = FespalierController(client);
    await pumpEventQueue();
    controller.dispose();
    client.calls.clear();
    client.emit(DevToolsEvents.registered, {'protocol': 1, 'event': 3});
    client.connected.value = false;
    client.restart();
    await pumpEventQueue();
    expect(client.calls, isEmpty);
  });
}
