// LiveFeed and LiveFeedFamily in a ProviderContainer, over FakeEventServer: signals, the tick,
// pauses, resume points, rebuilds and the status provider.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final url = Uri.parse('https://api.example.com/live');

/// A signal the test fires (core's `reconnectSignal` is one of these).
final networkBack = NotifierProvider.autoDispose<RefetchSignal, int>(
  RefetchSignal.new,
);

/// The signed-in user, which a feed's connect watches.
final user = NotifierProvider<UserNotifier, String>(UserNotifier.new);

class UserNotifier extends Notifier<String> {
  @override
  String build() => 'ada';

  void signIn(String name) => state = name;
}

Future<void> settle() => pumpEventQueue();

/// A few frames, with the microtasks and zero-length timers between them run.
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump();
  }
}

void main() {
  late FakeEventServer server;
  late ProviderContainer container;

  ManualStreamTicker ticker() =>
      container.read(streamTicker.notifier) as ManualStreamTicker;

  setUp(() {
    server = FakeEventServer();
    container = ProviderContainer(overrides: streamTestOverrides());
  });
  tearDown(() => container.dispose());

  LiveFeed<ServerEvent> feed({
    LiveRules rules = const LiveRules(),
    bool keepAlive = false,
    List<String?>? resumedFrom,
  }) => LiveFeed<ServerEvent>(
    (ref, lastEventId) {
      resumedFrom?.add(lastEventId);
      return ServerEvents(server, url, lastEventId: lastEventId);
    },
    rules: rules,
    keepAlive: keepAlive,
  );

  test(
    'latest is the last event; a drop is a status, never an error',
    () async {
      final live = feed();
      final values = <AsyncValue<ServerEvent>>[];
      final sub = container.listen(live.latest, (_, next) => values.add(next));
      final statuses = container.listen(live.status, (_, _) {});
      expect(container.read(live.latest).isLoading, isTrue);
      await settle();
      expect(statuses.read().value, const LiveOpen());
      server.current.event('a');
      await settle();
      expect(container.read(live.latest).value?.data, 'a');
      server.current.drop();
      await settle();
      final state = container.read(live.latest);
      expect(state.hasError, isFalse);
      expect(state.value?.data, 'a');
      expect((statuses.read().value! as LiveWaiting).drop, LiveDrop.failed);
      sub.close();
      statuses.close();
    },
  );

  test('a repeated event still reaches the watcher', () async {
    final live = feed();
    var notified = 0;
    final sub = container.listen(live.latest, (_, _) => notified++);
    await settle();
    server.current
      ..event('same')
      ..event('same');
    await settle();
    expect(notified, 2);
    sub.close();
  });

  test(
    'a signal reconnects a waiting connection, and only a waiting one',
    () async {
      final live = feed(rules: LiveRules(reconnectOn: [networkBack]));
      final sub = container.listen(live.latest, (_, _) {});
      final status = container.listen(live.status, (_, _) {});
      await settle();
      container.read(networkBack.notifier).fire();
      await settle();
      expect(
        server.requests,
        hasLength(1),
        reason: 'open: the signal changes nothing',
      );
      server.current.drop();
      await settle();
      container.read(networkBack.notifier).fire();
      await settle();
      expect(server.requests, hasLength(2));
      expect(status.read().value, const LiveOpen());
      sub.close();
      status.close();
    },
  );

  test(
    'the tick reconnects a waiting connection once its retry hint passed',
    () async {
      final live = feed();
      final sub = container.listen(live.latest, (_, _) {});
      final statuses = container.listen(live.status, (_, _) {});
      await settle();
      server.current.drop();
      await settle();
      ticker().tick();
      await settle();
      expect(server.requests, hasLength(2));
      server.current
        ..retry(const Duration(hours: 1))
        ..drop();
      await settle();
      ticker().tick();
      await settle();
      expect(
        server.requests,
        hasLength(2),
        reason: 'the server asked for an hour',
      );
      expect(statuses.read().value, isA<LiveWaiting>());
      sub.close();
      statuses.close();
    },
  );

  test(
    'the tick closes a connection paused for a whole tick; a resume reopens it',
    () async {
      final live = feed();
      final sub = container.listen(live.latest, (_, _) {});
      final status = container.listen(live.status, (_, _) {});
      await settle();
      server.current.event('a', id: '9');
      await settle();
      sub.pause();
      status.pause();
      await settle();
      expect(server.current.aborted, isFalse);
      ticker().tick();
      await settle();
      expect(
        server.current.aborted,
        isFalse,
        reason: 'the first tick only sees it',
      );
      ticker().tick();
      await settle();
      expect(server.current.aborted, isTrue);
      expect(server.requests, hasLength(1));
      sub.resume();
      status.resume();
      await settle();
      expect(server.requests, hasLength(2));
      expect(server.current.lastEventId, '9');
      expect(status.read().value, const LiveOpen(resumed: true));
      sub.close();
      status.close();
    },
  );

  test('a signal seen while paused reconnects on resume', () async {
    final live = feed(rules: LiveRules(reconnectOn: [networkBack]));
    final keep = container.listen(networkBack, (_, _) {});
    final sub = container.listen(live.latest, (_, _) {});
    await settle();
    server.current.drop();
    await settle();
    sub.pause();
    await settle();
    container.read(networkBack.notifier).fire();
    await settle();
    expect(server.requests, hasLength(1));
    sub.resume();
    await settle();
    expect(server.requests, hasLength(2));
    sub.close();
    keep.close();
  });

  test(
    'the tick closes an idle connection when the feed has an idle limit',
    () async {
      final live = feed(rules: const LiveRules(idle: Duration.zero));
      final sub = container.listen(live.latest, (_, _) {});
      final status = container.listen(live.status, (_, _) {});
      await settle();
      ticker().tick();
      await settle();
      expect(server.connections.first.aborted, isTrue);
      expect(status.read().value, isA<LiveWaiting>());
      ticker().tick();
      await settle();
      expect(
        server.requests,
        hasLength(2),
        reason: 'an idle drop reconnects on the next tick',
      );
      sub.close();
      status.close();
    },
  );

  test(
    'without an idle limit the tick leaves a quiet connection alone',
    () async {
      final live = feed();
      final sub = container.listen(live.latest, (_, _) {});
      await settle();
      ticker()
        ..tick()
        ..tick();
      await settle();
      expect(server.current.aborted, isFalse);
      sub.close();
    },
  );

  test(
    'the last event ID survives the feed being unwatched, and resumes it',
    () async {
      final resumedFrom = <String?>[];
      final live = feed(resumedFrom: resumedFrom);
      var sub = container.listen(live.latest, (_, _) {});
      await settle();
      server.current.event('a', id: '5');
      await settle();
      sub.close();
      await settle();
      expect(
        server.current.aborted,
        isTrue,
        reason: 'disposed, connection closed',
      );
      expect(container.read(liveResumePoints).length, 1);
      sub = container.listen(live.latest, (_, _) {});
      await settle();
      expect(resumedFrom, [null, '5']);
      expect(server.current.lastEventId, '5');
      sub.close();
    },
  );

  test('liveResumePoints.clear forgets them (sign-out)', () async {
    final resumedFrom = <String?>[];
    final live = feed(resumedFrom: resumedFrom);
    var sub = container.listen(live.latest, (_, _) {});
    await settle();
    server.current.event('a', id: '5');
    await settle();
    sub.close();
    await settle();
    container.read(liveResumePoints).clear();
    sub = container.listen(live.latest, (_, _) {});
    await settle();
    expect(resumedFrom, [null, null]);
    expect(server.current.lastEventId, isNull);
    sub.close();
  });

  test(
    'a rebuild (the user changed) replaces the connection and starts afresh',
    () async {
      final resumedFrom = <String?>[];
      final live = LiveFeed<ServerEvent>((ref, lastEventId) {
        resumedFrom.add(lastEventId);
        return ServerEvents(
          server,
          url,
          headers: {'X-User': ref.watch(user)},
          lastEventId: lastEventId,
        );
      });
      final sub = container.listen(live.latest, (_, _) {});
      final status = container.listen(live.status, (_, _) {});
      await settle();
      server.current.event('a', id: '5');
      await settle();
      container.read(user.notifier).signIn('bob');
      await settle();
      expect(server.connections.first.aborted, isTrue);
      expect(server.connections, hasLength(2));
      expect(server.current.header('X-User'), 'bob');
      expect(server.current.lastEventId, isNull);
      expect(resumedFrom, [null, null]);
      expect(status.read().value, const LiveOpen());
      sub.close();
      status.close();
    },
  );

  test(
    'a refusal is the error of latest, kept, with no timer and no new request',
    () async {
      server.respond(403);
      final live = feed();
      final sub = container.listen(live.latest, (_, _) {});
      final status = container.listen(live.status, (_, _) {});
      await settle();
      final state = container.read(live.latest);
      expect(state.error, isA<ServerEventsRefused>());
      expect(status.read().value, const LiveDone(LiveEnd.refused));
      status.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.requests, hasLength(1));
      sub.close();
    },
  );

  test('a connect that throws is the error of latest', () async {
    final live = LiveFeed<ServerEvent>((ref, _) => throw StateError('no api'));
    final sub = container.listen(live.latest, (_, _) {});
    final status = container.listen(live.status, (_, _) {});
    await settle();
    expect(container.read(live.latest).error, isStateError);
    expect(status.read().value, const LiveDone(LiveEnd.failed));
    sub.close();
    status.close();
  });

  test(
    'a keepAlive feed keeps its connection when nothing watches it',
    () async {
      final live = feed(keepAlive: true);
      final sub = container.listen(live.latest, (_, _) {});
      await settle();
      sub.close();
      await settle();
      expect(server.current.aborted, isFalse);
      container.dispose();
      await settle();
      expect(server.current.aborted, isTrue);
      container = ProviderContainer(overrides: streamTestOverrides());
    },
  );

  test(
    'the ticker looks after the connections of the feeds that exist',
    () async {
      final live = feed();
      final sub = container.listen(live.latest, (_, _) {});
      await settle();
      expect(ticker().trackedCount, 1);
      final keepTicker = container.listen(streamTicker, (_, _) {});
      sub.close();
      await settle();
      expect(ticker().trackedCount, 0);
      keepTicker.close();
    },
  );

  test('a mapped connection maps the events', () async {
    final live = LiveFeed<int>(
      (ref, lastEventId) =>
          ServerEvents(server, url).map((e) => int.parse(e.data)),
    );
    final sub = container.listen(live.latest, (_, _) {});
    await settle();
    server.current.event('42');
    await settle();
    expect(container.read(live.latest).value, 42);
    sub.close();
  });

  testWidgets(
    'a hidden page pauses its feed, the tick closes it, showing the page reopens it',
    (tester) async {
      final live = feed();
      final shown = ValueNotifier<bool>(true);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ValueListenableBuilder<bool>(
              valueListenable: shown,
              builder: (context, enabled, _) => TickerMode(
                enabled: enabled,
                child: Consumer(
                  builder: (context, ref, _) =>
                      Text(ref.watch(live.latest).value?.data ?? 'loading'),
                ),
              ),
            ),
          ),
        ),
      );
      await frames(tester);
      server.current.event('first', id: '1');
      await frames(tester);
      expect(find.text('first'), findsOneWidget);

      shown.value = false;
      await frames(tester);
      // A paused reader stops at the chunk it was waiting for: it is read, held, and nothing after.
      server.current.event('while hidden', id: '2');
      await frames(tester);
      expect(server.current.isPaused, isTrue);
      expect(find.text('first'), findsOneWidget);
      ticker().tick();
      ticker().tick();
      await frames(tester);
      expect(server.current.aborted, isTrue);
      expect(server.requests, hasLength(1));

      shown.value = true;
      await frames(tester);
      await frames(tester);
      expect(find.text('while hidden'), findsOneWidget);
      expect(server.requests, hasLength(2));
      expect(server.current.lastEventId, '2');
      server.current.event('second');
      await frames(tester);
      expect(find.text('second'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  group('LiveFeedFamily', () {
    test(
      'one connection per key, each with its status and resume point',
      () async {
        final seen = <(int, String?)>[];
        final orders = LiveFeedFamily<ServerEvent, int>((ref, id, lastEventId) {
          seen.add((id, lastEventId));
          return ServerEvents(
            server,
            url.replace(path: '/orders/$id/live'),
            lastEventId: lastEventId,
          );
        });
        final one = container.listen(orders(1), (_, _) {});
        final two = container.listen(orders(2), (_, _) {});
        final status = container.listen(orders.status(1), (_, _) {});
        await settle();
        expect(server.connections, hasLength(2));
        expect(status.read().value, const LiveOpen());
        status.close();
        server.connections[0].event('a', id: 'one-1');
        server.connections[1].event('b', id: 'two-1');
        await settle();
        expect(container.read(orders(1)).value?.data, 'a');
        expect(container.read(orders(2)).value?.data, 'b');
        one.close();
        await settle();
        expect(server.connections[0].aborted, isTrue);
        expect(server.connections[1].aborted, isFalse);
        final again = container.listen(orders(1), (_, _) {});
        await settle();
        expect(seen, [(1, null), (2, null), (1, 'one-1')]);
        expect(server.current.request.uri.path, '/orders/1/live');
        again.close();
        two.close();
      },
    );
  });

  group('FakeLiveConnection', () {
    test('a feed over it: events, status and what the tick asks', () async {
      final fake = FakeLiveConnection<String>();
      final live = LiveFeed<String>(
        (ref, _) => fake,
        rules: const LiveRules(idle: Duration(seconds: 30)),
      );
      final sub = container.listen(live.latest, (_, _) {});
      final status = container.listen(live.status, (_, _) {});
      await settle();
      expect(fake.listenCount, 1);
      fake
        ..setStatus(const LiveOpen())
        ..emit('x');
      await settle();
      expect(container.read(live.latest).value, 'x');
      expect(status.read().value, const LiveOpen());
      ticker().tick();
      expect(fake.pauseChecks, 1);
      expect(fake.idleChecks, [const Duration(seconds: 30)]);
      fake.setStatus(LiveWaiting(LiveDrop.failed, since: DateTime(2026)));
      ticker().tick();
      expect(fake.reconnectCount, 1);
      sub.close();
      status.close();
      await settle();
      expect(fake.closed, isTrue);
    });
  });

  test('a FakeEventServer answer in flight is aborted with the feed', () async {
    server.hang();
    final live = feed();
    final sub = container.listen(live.latest, (_, _) {});
    await settle();
    sub.close();
    await settle();
    expect(server.abortCount, 1);
    expect(server.requests.single.abortTrigger, isNotNull);
  });

  test('a decorator sees the request like any other', () async {
    final seen = <TransportRequest>[];
    final decorated = _Recording(server, seen);
    final live = LiveFeed<ServerEvent>(
      (ref, _) => ServerEvents(decorated, url),
    );
    final sub = container.listen(live.latest, (_, _) {});
    await settle();
    expect(seen.single.headers['Accept'], 'text/event-stream');
    sub.close();
  });
}

final class _Recording implements HttpTransport {
  _Recording(this.inner, this.seen);

  final HttpTransport inner;
  final List<TransportRequest> seen;

  @override
  Future<TransportResponse> send(TransportRequest request) {
    seen.add(request);
    return inner.send(request);
  }
}
