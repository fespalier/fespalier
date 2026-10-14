// FespalierController and the adapters (since 0.16.0): what it merges from their events, when it
// asks the app again, and what setting a value does.
import 'package:fespalier_devtools/src/controller.dart';
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'trace_fixtures.dart';

Future<FespalierController> started(FakeFespalierClient client) async {
  final controller = FespalierController(client);
  addTearDown(controller.dispose);
  await pumpEventQueue();
  return controller;
}

AdapterRecord record(
  String adapter, {
  int seq = 20,
  String text = 'on',
  bool removed = false,
}) => AdapterRecord(
  seq: seq,
  adapter: adapter,
  at: 1696230009000,
  values: removed
      ? const []
      : [AdapterValueRecord(key: 'k', value: Shown('String', text))],
  removed: removed,
);

FakeFespalierClient app() =>
    FakeFespalierClient(snapshot: fixture('snapshot_adapters'));

void main() {
  group('the snapshot', () {
    test('has the adapters the app showed', () async {
      final controller = await started(app());
      expect(
        [for (final a in controller.snapshot!.adapters) a.adapter],
        ['fespalier_flags', 'fespalier_launch'],
      );
      expect(controller.supports(DevToolsFeatures.adapters), isTrue);
    });

    test(
      'of an app older than 0.16.0 has none, and nothing to ask for',
      () async {
        final client = FakeFespalierClient(features: featuresBeforeAdapters);
        final controller = await started(client);
        expect(controller.snapshot!.adapters, isEmpty);
        expect(controller.supports(DevToolsFeatures.adapters), isFalse);
      },
    );
  });

  group('adapter events', () {
    test(
      'one that is next in line is put in by name, without a call',
      () async {
        final client = app();
        final controller = await started(client);
        client.calls.clear();
        client.emit(
          DevToolsEvents.adapter,
          recordEvent(13, record('fespalier_connectivity').toJson()),
        );
        await pumpEventQueue();
        expect(client.calls, isEmpty);
        expect(
          [for (final a in controller.snapshot!.adapters) a.adapter],
          ['fespalier_connectivity', 'fespalier_flags', 'fespalier_launch'],
        );
        expect(controller.snapshot!.event, 13);
      },
    );

    test('one of an adapter it has replaces that one, in place', () async {
      final client = app();
      final controller = await started(client);
      client.emit(
        DevToolsEvents.adapter,
        recordEvent(13, record('fespalier_flags', text: 'off').toJson()),
      );
      await pumpEventQueue();
      final flags = controller.snapshot!.adapters.first;
      expect(flags.adapter, 'fespalier_flags');
      expect(flags.values.single.value.text, 'off');
      expect(controller.snapshot!.adapters, hasLength(2));
    });

    test('a removed record drops its adapter', () async {
      final client = app();
      final controller = await started(client);
      client.emit(
        DevToolsEvents.adapter,
        recordEvent(13, record('fespalier_flags', removed: true).toJson()),
      );
      await pumpEventQueue();
      expect(
        [for (final a in controller.snapshot!.adapters) a.adapter],
        ['fespalier_launch'],
      );
      // One that is not there changes nothing.
      client.emit(
        DevToolsEvents.adapter,
        recordEvent(14, record('nobody', removed: true).toJson()),
      );
      await pumpEventQueue();
      expect(controller.snapshot!.adapters, hasLength(1));
      expect(controller.snapshot!.event, 14);
    });

    test('merging keeps the rest of the snapshot', () async {
      final client = FakeFespalierClient(
        snapshot: {
          ...fixture('snapshot_adapters'),
          'guards': [guardRecord(1).toJson()],
          'data': [dataRecord(1).toJson()],
          'actions': [actionRecord(1).toJson()],
        },
      );
      final controller = await started(client);
      client.emit(
        DevToolsEvents.adapter,
        recordEvent(13, record('fespalier_flags').toJson()),
      );
      await pumpEventQueue();
      final snapshot = controller.snapshot!;
      expect(snapshot.guards, hasLength(1));
      expect(snapshot.data, hasLength(1));
      expect(snapshot.actions, hasLength(1));
      expect(snapshot.stack, isNotEmpty);
      expect(snapshot.location, isNotNull);
    });

    test('one the snapshot already has is not merged again', () async {
      final client = app();
      final controller = await started(client);
      client.calls.clear();
      client.emit(
        DevToolsEvents.adapter,
        recordEvent(12, record('fespalier_flags', text: 'late').toJson()),
      );
      await pumpEventQueue();
      expect(client.calls, isEmpty);
      expect(
        controller.snapshot!.adapters.first.values.first.value.text,
        isNot('late'),
      );
    });

    test('one after a gap fetches the snapshot again', () async {
      final client = app();
      final controller = await started(client);
      client.calls.clear();
      client.snapshot = {
        ...fixture('snapshot_adapters'),
        'event': 15,
        'adapters': <Object?>[],
      };
      client.emit(
        DevToolsEvents.adapter,
        recordEvent(15, record('fespalier_flags').toJson()),
      );
      await pumpEventQueue();
      expect(client.callsTo(DevToolsMethods.snapshot), hasLength(1));
      expect(controller.snapshot!.adapters, isEmpty);
      expect(controller.snapshot!.event, 15);
    });

    test('a record it cannot read fetches the snapshot again', () async {
      final client = app();
      await started(client);
      client.calls.clear();
      client.emit(DevToolsEvents.adapter, recordEvent(13, {'adapter': 'x'}));
      await pumpEventQueue();
      expect(client.callsTo(DevToolsMethods.snapshot), hasLength(1));
    });

    test('a hot restart forgets the adapters of the old app', () async {
      final client = app();
      final controller = await started(client);
      client.snapshot = tracedSnapshot();
      client.restart();
      await pumpEventQueue();
      expect(controller.snapshot!.adapters, isEmpty);
    });
  });

  group('adapterEdit', () {
    test(
      'asks the app with the adapter, the key and the text, and is null on ok',
      () async {
        final client = app();
        final controller = await started(client);
        final reason = await controller.adapterEdit(
          'fespalier_flags',
          'new_checkout',
          'false',
        );
        expect(reason, isNull);
        expect(client.callsTo(DevToolsMethods.adapterEdit), [
          {
            'adapter': 'fespalier_flags',
            'key': 'new_checkout',
            'value': 'false',
          },
        ]);
      },
    );

    test('an empty text is sent as it is', () async {
      final client = app();
      final controller = await started(client);
      await controller.adapterEdit('fespalier_flags', 'limit', '');
      expect(client.callsTo(DevToolsMethods.adapterEdit).single['value'], '');
    });

    test('answers the reason the app gave when it said no', () async {
      final controller = await started(
        FakeFespalierClient(
          snapshot: fixture('snapshot_adapters'),
          handlers: {
            DevToolsMethods.adapterEdit: (_) => {
              'protocol': 1,
              'ok': false,
              'reason': 'onEdit threw: Bad state: no flags yet',
            },
          },
        ),
      );
      expect(
        await controller.adapterEdit('fespalier_flags', 'limit', '7'),
        'onEdit threw: Bad state: no flags yet',
      );
    });

    test('says so when the app said no without a reason', () async {
      final controller = await started(
        FakeFespalierClient(
          snapshot: fixture('snapshot_adapters'),
          handlers: {
            DevToolsMethods.adapterEdit: (_) => {'protocol': 1, 'ok': false},
          },
        ),
      );
      expect(
        await controller.adapterEdit('fespalier_flags', 'limit', '7'),
        'the app did not set `limit`',
      );
    });

    test(
      'answers the error when the call failed, and leaves the action error alone',
      () async {
        final controller = await started(
          FakeFespalierClient(
            snapshot: fixture('snapshot_adapters'),
            handlers: {
              DevToolsMethods.adapterEdit: (_) =>
                  throw StateError('the VM went away'),
            },
          ),
        );
        expect(
          await controller.adapterEdit('fespalier_flags', 'limit', '7'),
          'Bad state: the VM went away',
        );
        expect(controller.actionError, isNull);
      },
    );
  });
}
