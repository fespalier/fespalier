// The package's telemetry contract: two short root spans per connection, constants only. Nothing
// from the wire (an event's type, data or id), the URL, a header or an error's text is reported.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

final url = Uri.parse('https://api.example.com/orders/live?token=secret-q');

/// Remembers what the zone it was started in held under `#probe`, as a sink that reads its parent
/// span from `Zone.current` does.
final class ZoneProbeTelemetry extends FespalierTelemetry {
  final List<Object?> seen = [];

  @override
  Object? start(TelemetryStart start) {
    seen.add(Zone.current[#probe]);
    return null;
  }
}

Future<void> settle() => pumpEventQueue();

void main() {
  late RecordingTelemetry sink;
  late FakeEventServer server;

  setUp(() {
    sink = RecordingTelemetry();
    FespalierTelemetry.install(sink);
    server = FakeEventServer();
  });
  tearDown(() => FespalierTelemetry.install(null));

  test('the names are the contract', () {
    expect(FespalierStreamConventions.open, 'fespalier.stream.open');
    expect(FespalierStreamConventions.close, 'fespalier.stream.close');
    expect(FespalierStreamConventions.kind, 'fespalier.stream.kind');
    expect(FespalierStreamConventions.kindSse, 'sse');
    expect(FespalierStreamConventions.name, 'fespalier.stream.name');
    expect(FespalierStreamConventions.result, 'fespalier.stream.result');
    expect(FespalierStreamConventions.resumed, 'fespalier.stream.resumed');
    expect(
      FespalierStreamConventions.statusCode,
      'fespalier.stream.status_code',
    );
    expect(FespalierStreamConventions.reason, 'fespalier.stream.reason');
    expect(FespalierStreamConventions.events, 'fespalier.stream.events');
  });

  test('a connection is an open span at its answer and a close span at its end', () async {
    final events = ServerEvents(server, url, name: 'orders');
    final sub = events.events.listen((_) {});
    await settle();
    server.current
      ..event('secret-data', type: 'secret-type', id: 'secret-id')
      ..event('more')
      ..end();
    await settle();
    await sub.cancel();
    await settle();
    expect(sink.log, [
      '#1 start custom fespalier.stream.open fespalier.stream.kind=sse '
          'fespalier.stream.name=orders fespalier.stream.resumed=false',
      '#1 end custom ok async fespalier.stream.result=open fespalier.stream.status_code=200',
      '#2 start custom fespalier.stream.close fespalier.stream.kind=sse fespalier.stream.name=orders',
      '#2 end custom ok fespalier.stream.events=2 fespalier.stream.reason=ended',
      '#3 start custom fespalier.stream.open fespalier.stream.kind=sse '
          'fespalier.stream.name=orders fespalier.stream.resumed=true',
      '#3 end custom ok async fespalier.stream.result=open fespalier.stream.status_code=200',
      '#4 start custom fespalier.stream.close fespalier.stream.kind=sse fespalier.stream.name=orders',
      '#4 end custom ok fespalier.stream.events=0 fespalier.stream.reason=cancelled',
    ]);
    final all = sink.log.join('\n');
    for (final secret in ['secret', 'example.com', 'token', '/orders']) {
      expect(all, isNot(contains(secret)));
    }
  });

  test('the start carries the kind, the name and whether it resumed', () async {
    final starts = <TelemetryStart>[];
    FespalierTelemetry.install(_Starts(starts));
    final events = ServerEvents(server, url, name: 'orders', lastEventId: '7');
    final sub = events.events.listen((_) {});
    await settle();
    await sub.cancel();
    await settle();
    expect(starts.first.name, 'fespalier.stream.open');
    expect(starts.first.attributes, {
      'fespalier.stream.kind': 'sse',
      'fespalier.stream.name': 'orders',
      'fespalier.stream.resumed': true,
    });
    expect(starts.last.name, 'fespalier.stream.close');
    expect(starts.last.attributes, {
      'fespalier.stream.kind': 'sse',
      'fespalier.stream.name': 'orders',
    });
  });

  test(
    'each answer has its result, and an error carries no error object',
    () async {
      server
        ..fail(const TransportUnsent(FormatException('secret-cause')))
        ..respond(503)
        ..respond(200, headers: {'content-type': 'text/html'});
      final events = ServerEvents(server, url);
      final sub = events.events.listen((_) {}, onError: (Object _) {});
      await settle();
      events.reconnect();
      await settle();
      events.reconnect();
      await settle();
      await sub.cancel();
      expect(sink.log.where((l) => l.contains(' end ')), [
        '#1 end custom error async fespalier.stream.result=failed',
        '#2 end custom error async fespalier.stream.result=unavailable fespalier.stream.status_code=503',
        '#3 end custom error async fespalier.stream.result=rejected fespalier.stream.status_code=200',
      ]);
      expect(sink.log.join('\n'), isNot(contains('secret')));
    },
  );

  test('a refusal, a 204 and a cancelled request', () async {
    server.respond(403);
    var sub = ServerEvents(
      server,
      url,
    ).events.listen((_) {}, onError: (Object _) {});
    await settle();
    server.respond(204);
    sub = ServerEvents(server, url).events.listen((_) {});
    await settle();
    server.hang();
    sub = ServerEvents(server, url).events.listen((_) {});
    await settle();
    await sub.cancel();
    await settle();
    expect(sink.log.where((l) => l.contains(' end ')), [
      '#1 end custom rejected async fespalier.stream.result=refused fespalier.stream.status_code=403',
      '#2 end custom ok async fespalier.stream.result=done fespalier.stream.status_code=204',
      '#3 end custom cancelled async fespalier.stream.result=cancelled',
    ]);
  });

  test('closes for a drop, an idle connection and a long pause', () async {
    final events = ServerEvents(server, url);
    final sub = events.events.listen((_) {});
    await settle();
    server.current.drop(const FormatException('secret-reset'));
    await settle();
    events.reconnect();
    await settle();
    events.closeIfIdle(Duration.zero);
    await settle();
    events.reconnect();
    await settle();
    sub.pause();
    events
      ..closeIfPaused()
      ..closeIfPaused();
    await settle();
    await sub.cancel();
    expect(sink.log.where((l) => l.contains('fespalier.stream.reason')), [
      '#2 end custom error fespalier.stream.events=0 fespalier.stream.reason=failed',
      '#4 end custom ok fespalier.stream.events=0 fespalier.stream.reason=idle',
      '#6 end custom ok fespalier.stream.events=0 fespalier.stream.reason=paused',
    ]);
    expect(sink.log.join('\n'), isNot(contains('secret')));
  });

  test(
    'both spans are root spans, not children of the zone that listened',
    () async {
      final probe = ZoneProbeTelemetry();
      FespalierTelemetry.install(probe);
      late StreamSubscription<ServerEvent> sub;
      runZoned(() {
        sub = ServerEvents(server, url).events.listen((_) {});
      }, zoneValues: {#probe: 'page A'});
      await settle();
      server.current.end();
      await settle();
      await sub.cancel();
      expect(probe.seen, isNotEmpty);
      expect(probe.seen, everyElement(isNull));
    },
  );

  test('without a sink nothing is reported and nothing breaks', () async {
    FespalierTelemetry.install(null);
    final events = ServerEvents(server, url);
    final seen = <String>[];
    final sub = events.events.listen((e) => seen.add(e.data));
    await settle();
    server.current.event('a');
    await settle();
    await sub.cancel();
    expect(seen, ['a']);
    expect(sink.log, isEmpty);
  });

  test('a name that could be a URL or an id is refused in debug', () {
    expect(
      () => ServerEvents(server, url, name: 'Orders'),
      throwsAssertionError,
    );
    expect(
      () => ServerEvents(server, url, name: 'orders/42'),
      throwsAssertionError,
    );
    expect(ServerEvents(server, url, name: 'orders_live').name, 'orders_live');
  });
}

final class _Starts extends FespalierTelemetry {
  _Starts(this.starts);

  final List<TelemetryStart> starts;

  @override
  Object? start(TelemetryStart start) {
    starts.add(start);
    return starts.length;
  }
}
