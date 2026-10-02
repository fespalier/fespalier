// VmFespalierClient, with a fake of what DevTools' serviceManager gives it.
import 'dart:async';

import 'package:fespalier_devtools/src/client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

Event extensionEvent(
  String kind,
  Map<String, Object?> data, {
  String isolate = 'isolates/1',
  String eventKind = EventKind.kExtension,
}) => Event(
  kind: eventKind,
  timestamp: 0,
  isolate: IsolateRef(
    id: isolate,
    number: '1',
    name: 'main',
    isSystemIsolate: false,
  ),
  extensionKind: kind,
  extensionData: ExtensionData.parse(Map<String, dynamic>.of(data)),
);

IsolateRef isolateRef(String id) =>
    IsolateRef(id: id, number: '1', name: 'main', isSystemIsolate: false);

class Rig {
  Rig() {
    client = VmFespalierClient(
      callServiceExtension: (method, {args}) async {
        calls.add((method, args));
        return answer(method, args);
      },
      extensionEvents: () {
        subscribed++;
        return stream.stream;
      },
      connected: connected,
      hasFespalier: hasFespalier,
      mainIsolate: isolate,
    );
  }

  late final VmFespalierClient client;
  final stream = StreamController<Event>.broadcast();
  final connected = ValueNotifier<bool>(true);
  final hasFespalier = ValueNotifier<bool>(true);
  final isolate = ValueNotifier<IsolateRef?>(isolateRef('isolates/1'));
  final calls = <(String, Map<String, dynamic>?)>[];
  var subscribed = 0;
  FutureOr<Response> Function(String method, Map<String, dynamic>? args)
  answer = (method, args) => Response.parse({'type': 'Response', 'ok': true})!;

  void dispose() {
    client.dispose();
    unawaited(stream.close());
  }
}

void main() {
  late Rig rig;
  setUp(() => rig = Rig());
  tearDown(() => rig.dispose());

  group('call', () {
    test('decodes the JSON of the response', () async {
      rig.answer = (method, args) =>
          Response.parse({'type': 'Response', 'protocol': 1, 'ok': true})!;
      final answer = await rig.client.call('ext.fespalier.hello');
      expect(answer['protocol'], 1);
      expect(answer['ok'], true);
    });

    test('passes its parameters, and none as none', () async {
      await rig.client.call('ext.fespalier.snapshot');
      await rig.client.call('ext.fespalier.navigate', {
        'mode': 'go',
        'location': '/b',
      });
      expect(rig.calls.map((c) => c.$1), [
        'ext.fespalier.snapshot',
        'ext.fespalier.navigate',
      ]);
      expect(rig.calls[0].$2, isNull);
      expect(rig.calls[1].$2, {'mode': 'go', 'location': '/b'});
    });

    test(
      'maps an RPCError to a FespalierError with the app\'s message',
      () async {
        rig.answer = (method, args) => throw RPCError.withDetails(
          method,
          -32602,
          'Invalid params',
          details: 'missing parameter `location`',
        );
        await expectLater(
          rig.client.call('ext.fespalier.navigate', {'mode': 'go'}),
          throwsA(
            isA<FespalierError>()
                .having(
                  (e) => e.message,
                  'message',
                  'missing parameter `location`',
                )
                .having((e) => e.code, 'code', -32602),
          ),
        );
      },
    );

    test('an RPCError with no details says what the VM said', () async {
      rig.answer = (method, args) =>
          throw RPCError(method, 113, 'Method not found');
      await expectLater(
        rig.client.call('ext.fespalier.hello'),
        throwsA(
          isA<FespalierError>().having(
            (e) => e.message,
            'message',
            'Method not found',
          ),
        ),
      );
    });
  });

  group('events', () {
    test('passes fespalier\'s, with their payloads', () async {
      final seen = <FespalierEvent>[];
      final sub = rig.client.events.listen(seen.add);
      rig.stream.add(
        extensionEvent('fespalier:navigation', {'protocol': 1, 'event': 4}),
      );
      await pumpEventQueue();
      await sub.cancel();
      expect(seen, hasLength(1));
      expect(seen.single.kind, 'fespalier:navigation');
      expect(seen.single.payload, {'protocol': 1, 'event': 4});
    });

    test('filters out what is not fespalier\'s', () async {
      final seen = <FespalierEvent>[];
      final sub = rig.client.events.listen(seen.add);
      rig.stream.add(extensionEvent('riverpod:provider_changed', {'a': 1}));
      rig.stream.add(
        extensionEvent('fespalier:navigation', {
          'event': 1,
        }, eventKind: EventKind.kLogging),
      );
      rig.stream.add(extensionEvent('fespalier:registered', {'event': 2}));
      await pumpEventQueue();
      await sub.cancel();
      expect(seen.map((e) => e.kind), ['fespalier:registered']);
    });

    test('filters out the events of another isolate', () async {
      final seen = <FespalierEvent>[];
      final sub = rig.client.events.listen(seen.add);
      rig.stream.add(
        extensionEvent('fespalier:navigation', {
          'event': 1,
        }, isolate: 'isolates/9'),
      );
      rig.stream.add(extensionEvent('fespalier:navigation', {'event': 2}));
      await pumpEventQueue();
      await sub.cancel();
      expect(seen.map((e) => e.payload['event']), [2]);
    });

    test('an event with no data has an empty payload', () async {
      final seen = <FespalierEvent>[];
      final sub = rig.client.events.listen(seen.add);
      rig.stream.add(
        Event(
          kind: EventKind.kExtension,
          timestamp: 0,
          extensionKind: 'fespalier:registered',
        ),
      );
      await pumpEventQueue();
      await sub.cancel();
      expect(seen.single.payload, isEmpty);
    });
  });

  group('restarts', () {
    test('fire when the main isolate changes', () {
      var fired = 0;
      rig.client.restarts.addListener(() => fired++);
      rig.isolate.value = isolateRef('isolates/2');
      expect(fired, 1);
      // The same isolate again, or none for a moment, is not a new app.
      rig.isolate.value = isolateRef('isolates/2');
      rig.isolate.value = null;
      expect(fired, 1);
    });

    test(
      'fire on a new connection, which has a service of its own to listen to',
      () {
        var fired = 0;
        rig.client.restarts.addListener(() => fired++);
        expect(rig.subscribed, 1);
        rig.connected.value = false;
        expect(fired, 0);
        rig.connected.value = true;
        expect(fired, 1);
        expect(rig.subscribed, 2);
      },
    );

    test('events of the new isolate pass, and the old one\'s stop', () async {
      final seen = <FespalierEvent>[];
      final sub = rig.client.events.listen(seen.add);
      rig.isolate.value = isolateRef('isolates/2');
      rig.stream.add(extensionEvent('fespalier:navigation', {'event': 1}));
      rig.stream.add(
        extensionEvent('fespalier:navigation', {
          'event': 2,
        }, isolate: 'isolates/2'),
      );
      await pumpEventQueue();
      await sub.cancel();
      expect(seen.map((e) => e.payload['event']), [2]);
    });
  });

  test('is connected and has fespalier as the notifiers it was given say', () {
    expect(rig.client.connected, same(rig.connected));
    expect(rig.client.hasFespalier, same(rig.hasFespalier));
  });
}
