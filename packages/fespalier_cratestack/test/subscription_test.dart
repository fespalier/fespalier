// A CrateStack subscription (since 0.25.0): `GET <base>/rpc/subscribe/<opId>` read by
// crateStackEvents, against the bytes a CrateStack 0.15.4 server wrote (captured with curl, see
// docs/cratestack.md "Subscriptions"): `event: message` with `{"id": n, "next": ModelEvent}`, no
// `id:` field, and `event: error` before the server ends a subscriber that lagged.
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// Three events, byte for byte as CrateStack 0.15.4 sent them.
const capturedEvents =
    'event: message\n'
    'data: {"id":1,"next":{"event_id":"5061bc41-c1d0-4117-8a39-a62be3c418a8","model":"Note","operation":"Created","occurred_at":"2026-10-28T20:05:22.370140Z","data":{"id":1,"text":"xxxxx"}}}\n'
    '\n'
    'event: message\n'
    'data: {"id":2,"next":{"event_id":"b77a43ca-6867-4e82-ba13-dd72c8bbfe8f","model":"Note","operation":"Created","occurred_at":"2026-10-28T20:05:22.375355Z","data":{"id":2,"text":"xxxxx"}}}\n'
    '\n'
    'event: message\n'
    'data: {"id":3,"next":{"event_id":"b5dcb538-ebae-4b3e-bb28-bd8849509ab6","model":"Note","operation":"Created","occurred_at":"2026-10-28T20:05:22.377353Z","data":{"id":3,"text":"xxxxx"}}}\n'
    '\n';

/// The lag notice, byte for byte, after which the server ends the response.
const capturedLag =
    'event: error\n'
    'data: {"id":139,"err":{"code":"unavailable","message":"subscription lagged"}}\n'
    '\n';

final base = Uri.parse('https://api.example.com/');

Future<void> settle() => pumpEventQueue();

void main() {
  late FakeEventServer server;

  setUp(() => server = FakeEventServer());

  test('the captured events decode, whole or cut anywhere', () async {
    for (final size in [capturedEvents.length, 1, 7, 64]) {
      final connection = crateStackEvents(
        server,
        base,
        'model.Note.subscribe',
        keepData: true,
      );
      final events = <CrateStackModelEvent>[];
      final sub = connection.events.listen(events.add);
      await settle();
      final bytes = utf8.encode(capturedEvents);
      for (var i = 0; i < bytes.length; i += size) {
        server.current.writeBytes(
          bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size),
        );
      }
      await settle();
      expect(events, hasLength(3), reason: 'chunks of $size');
      expect([for (final e in events) e.sequence], [1, 2, 3]);
      final first = events.first;
      expect(first.model, 'Note');
      expect(first.operation, 'Created');
      expect(first.isCreated, isTrue);
      expect(first.eventId, '5061bc41-c1d0-4117-8a39-a62be3c418a8');
      expect(first.occurredAt, DateTime.utc(2026, 10, 28, 20, 5, 22, 370, 140));
      expect(first.data, {'id': 1, 'text': 'xxxxx'});
      await sub.cancel();
    }
  });

  test('the row is a hint and is not kept unless asked for', () async {
    final connection = crateStackEvents(server, base, 'model.Note.subscribe');
    final events = <CrateStackModelEvent>[];
    final sub = connection.events.listen(events.add);
    await settle();
    server.current.write(capturedEvents);
    await settle();
    expect(events, hasLength(3));
    expect(events.map((e) => e.data), everyElement(isNull));
    expect(events.first.model, 'Note');
    expect(events.first.eventId, isNotNull);
    await sub.cancel();
  });

  test(
    'the request: GET on rpc/subscribe, asking for an event stream, never resuming',
    () async {
      for (final (given, expected) in [
        (
          'https://api.example.com',
          'https://api.example.com/rpc/subscribe/model.Note.subscribe',
        ),
        (
          'https://api.example.com/',
          'https://api.example.com/rpc/subscribe/model.Note.subscribe',
        ),
        (
          'https://api.example.com:8443/shop/?debug=1#x',
          'https://api.example.com:8443/shop/rpc/subscribe/model.Note.subscribe',
        ),
      ]) {
        expect(
          '${crateStackSubscribeUrl(Uri.parse(given), 'model.Note.subscribe')}',
          expected,
        );
      }

      final connection = crateStackEvents(
        server,
        base,
        'model.Note.subscribe',
        // CrateStack answers 406 to anything but text/event-stream or */*: an Accept given here
        // is replaced.
        headers: {'accept': 'application/json', 'X-Tenant': 'shop'},
      );
      final sub = connection.events.listen((_) {});
      await settle();
      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(
        '${request.uri}',
        'https://api.example.com/rpc/subscribe/model.Note.subscribe',
      );
      expect(server.current.header('accept'), 'text/event-stream');
      expect(server.current.header('x-tenant'), 'shop');
      expect(server.current.lastEventId, isNull);
      await sub.cancel();
    },
  );

  test(
    'the lag notice is dropped, the response ends, and the reopen cannot resume',
    () async {
      final connection = crateStackEvents(server, base, 'model.Note.subscribe');
      final events = <CrateStackModelEvent>[];
      final sub = connection.events.listen(events.add);
      await settle();
      server.current
        ..write(capturedEvents)
        ..write(capturedLag)
        ..end();
      await settle();
      expect(events, hasLength(3), reason: 'the error is not a model event');
      expect(server.requests, hasLength(2), reason: 'it opened again at once');
      expect(server.current.lastEventId, isNull);
      expect(connection.status, const LiveOpen());
      await sub.cancel();
    },
  );

  test(
    'through ChangeFeed.live, a lag is a gap: every watched key moves at the reopen',
    () async {
      final container = ProviderContainer(overrides: streamTestOverrides());
      addTearDown(container.dispose);
      final changes = ChangeFeed<CrateStackModelEvent>.live((ref, lastEventId) {
        expect(lastEventId, isNull, reason: 'CrateStack sends no id:');
        return crateStackEvents(server, base, 'model.Note.subscribe');
      });
      final byModel = changes.topic<String>(
        (event, model) => event.model == model,
      );
      final notes = <int>[];
      final orders = <int>[];
      final any = <int>[];
      final subs = [
        container.listen(byModel('Note'), (_, next) => notes.add(next)),
        container.listen(byModel('Order'), (_, next) => orders.add(next)),
        container.listen(changes.any, (_, next) => any.add(next)),
      ];
      await settle();
      server.current.modelEvent('Note', 'Updated', data: {'id': 1});
      await settle();
      expect(notes, [1]);
      expect(orders, isEmpty);
      expect(any, [1]);

      server.current.lagged(sequence: 2);
      await settle();
      expect(server.requests, hasLength(2));
      expect(notes, [1, 2], reason: 'the gap moves Note');
      expect(orders, [1], reason: 'and Order, which no event named');
      expect(any, [1, 2]);
      for (final sub in subs) {
        sub.close();
      }
    },
  );

  test(
    'a message that does not decode is skipped and counted; another type is dropped',
    () async {
      final skipped = <Object>[];
      final connection = crateStackEvents(
        server,
        base,
        'model.Note.subscribe',
        onSkipped: (reason, _) => skipped.add(reason),
      );
      final events = <CrateStackModelEvent>[];
      final errors = <Object>[];
      final sub = connection.events.listen(events.add, onError: errors.add);
      await settle();
      server.current
        ..event('not json', type: 'message')
        ..event('{"id":1}', type: 'message')
        ..event('{"id":2,"next":{"model":"Note"}}', type: 'message')
        ..event('{"hello":1}', type: 'ping')
        ..modelEvent('Note', 'Deleted', sequence: 3);
      await settle();
      expect(events.single.isDeleted, isTrue);
      expect(skipped, hasLength(3));
      expect(skipped, everyElement(isA<FormatException>()));
      expect(errors, isEmpty, reason: 'a skip never ends the stream');
      await sub.cancel();
    },
  );

  test(
    'a refusal ends the connection: the 406 of a missing Accept, a 401',
    () async {
      for (final status in [401, 406]) {
        server.respond(
          status,
          headers: {'content-type': 'application/json'},
          body:
              '{"code":"invalid_argument","message":"subscription endpoint requires Accept: text/event-stream"}',
        );
        final connection = crateStackEvents(
          server,
          base,
          'model.Note.subscribe',
        );
        final errors = <Object>[];
        final sub = connection.events.listen((_) {}, onError: errors.add);
        await settle();
        expect(errors.single, isA<ServerEventsRefused>());
        expect(connection.status, const LiveDone(LiveEnd.refused));
        await sub.cancel();
      }
    },
  );

  test('toString names the model and the operation, never the data', () {
    final event = CrateStackModelEvent.fromJson(
      jsonDecode(
        '{"id":7,"next":{"event_id":"5061bc41-c1d0-4117-8a39-a62be3c418a8",'
        '"model":"Note","operation":"Updated","occurred_at":"2026-10-28T20:05:22Z",'
        '"data":{"id":1,"text":"a secret"}}}',
      ),
    );
    expect('$event', 'CrateStackModelEvent(Note Updated)');
    expect('$event', isNot(contains('secret')));
    expect('$event', isNot(contains('5061bc41')));
    expect(event.isUpdated, isTrue);
  });
}
