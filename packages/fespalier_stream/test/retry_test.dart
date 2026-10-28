// Riverpod 3 retries a provider that fails with an Exception, with a Timer (200 ms, doubling, ten
// times), and fespalier_stream starts no timer: every provider it declares passes `retry: null`,
// and a drop is a status, never an error. Under fake_async, no failure leaves a timer behind and
// none opens a second request by itself.
import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

final url = Uri.parse('https://api.example.com/live');

void main() {
  final cases = <String, void Function(FakeEventServer server)>{
    'a transport failure': (s) => s.fail(const TransportUnsent()),
    'a 503': (s) => s.respond(503),
    'a 429 with Retry-After': (s) =>
        s.respond(429, headers: {'Retry-After': '1'}),
    'a 403 (a refusal)': (s) => s.respond(403),
    'a 200 that is not an event stream': (s) => s.respond(200),
    'an error that is no Exception': (s) => s.fail(StateError('bug')),
  };

  for (final MapEntry(key: name, value: script) in cases.entries) {
    test('$name: no timer, and one request', () {
      fakeAsync((async) {
        final server = FakeEventServer();
        script(server);
        final live = LiveFeed<ServerEvent>(
          (ref, _) => ServerEvents(server, url),
        );
        final container = ProviderContainer(overrides: streamTestOverrides());
        final latest = container.listen(live.latest, (_, _) {});
        final status = container.listen(live.status, (_, _) {});
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(minutes: 2));
        expect(server.requests, hasLength(1));
        expect(async.pendingTimers, isEmpty);
        latest.close();
        status.close();
        container.dispose();
        async.flushMicrotasks();
      });
    });
  }

  test('a body that breaks: no timer, and the feed waits', () {
    fakeAsync((async) {
      final server = FakeEventServer();
      final live = LiveFeed<ServerEvent>((ref, _) => ServerEvents(server, url));
      final container = ProviderContainer(overrides: streamTestOverrides());
      final latest = container.listen(live.latest, (_, _) {});
      async.flushMicrotasks();
      server.current
        ..event('a')
        ..drop();
      async.flushMicrotasks();
      expect(container.read(live.latest).hasError, isFalse);
      async.elapse(const Duration(minutes: 2));
      expect(server.requests, hasLength(1));
      expect(async.pendingTimers, isEmpty);
      latest.close();
      container.dispose();
      async.flushMicrotasks();
    });
  });

  test('a connect that throws: kept, called once, no timer', () {
    fakeAsync((async) {
      var calls = 0;
      final live = LiveFeed<ServerEvent>((ref, _) {
        calls++;
        throw Exception('no transport');
      });
      final container = ProviderContainer(overrides: streamTestOverrides());
      final latest = container.listen(live.latest, (_, _) {});
      async.flushMicrotasks();
      expect(container.read(live.latest).hasError, isTrue);
      async.elapse(const Duration(minutes: 2));
      expect(calls, 1);
      expect(async.pendingTimers, isEmpty);
      latest.close();
      container.dispose();
    });
  });

  test(
    'the simple form in a StreamProvider with retry: null leaves no timer',
    () {
      fakeAsync((async) {
        final server = FakeEventServer()..fail(const TransportUnsent());
        final provider = StreamProvider<ServerEvent>(
          (ref) => server.serverEvents(url),
          retry: (_, _) => null,
        );
        final container = ProviderContainer();
        final sub = container.listen(provider, (_, _) {});
        async.flushMicrotasks();
        expect(container.read(provider).error, isA<TransportUnsent>());
        async.elapse(const Duration(minutes: 2));
        expect(server.requests, hasLength(1));
        expect(async.pendingTimers, isEmpty);
        sub.close();
        container.dispose();
      });
    },
  );
}
