// ChangeFeed.live (since 0.25.0): a change feed over a live connection, over FakeEventServer. The
// connection behaves as a LiveFeed's (signals, the tick, pauses, resume), and a reopen that did
// not resume is a gap: a new log, and every watched key moves once at that moment.
import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:flutter_test/flutter_test.dart';

final url = Uri.parse('https://api.example.com/changes');

/// A signal the test fires (core's `reconnectSignal` is one of these).
final networkBack = NotifierProvider.autoDispose<RefetchSignal, int>(
  RefetchSignal.new,
);

/// The signed-in user, which the feed's connect watches.
final user = NotifierProvider<UserNotifier, String>(UserNotifier.new);

class UserNotifier extends Notifier<String> {
  @override
  String build() => 'ada';

  void signIn(String name) => state = name;
}

Future<void> settle() => pumpEventQueue();

void main() {
  late FakeEventServer server;
  late ProviderContainer container;
  late List<String?> resumedFrom;
  late ChangeFeed<String> feed;
  late ChangeTopic<String, String> changed;

  /// What each watched key's revision was told, in order.
  late Map<String, List<int>> moves;
  late List<int> anyMoves;

  ManualStreamTicker ticker() =>
      container.read(streamTicker.notifier) as ManualStreamTicker;

  ChangeFeed<String> live({
    LiveRules rules = const LiveRules(),
    bool watchUser = false,
  }) => ChangeFeed<String>.live(
    (ref, lastEventId) {
      resumedFrom.add(lastEventId);
      return ServerEvents(
        server,
        url,
        headers: watchUser ? {'X-User': ref.watch(user)} : const {},
        lastEventId: lastEventId,
      ).map((event) => event.data);
    },
    rules: rules,
    name: 'changes',
  );

  /// Watches keys a, b and c and `any`, recording their moves.
  List<ProviderSubscription<int>> watch() {
    changed = feed.topic<String>((event, key) => event == key);
    return [
      for (final key in ['a', 'b', 'c'])
        container.listen(
          changed(key),
          (_, next) => (moves[key] ??= []).add(next),
        ),
      container.listen(feed.any, (_, next) => anyMoves.add(next)),
    ];
  }

  setUp(() {
    server = FakeEventServer();
    container = ProviderContainer(overrides: streamTestOverrides());
    resumedFrom = [];
    moves = {};
    anyMoves = [];
    feed = live();
  });
  tearDown(() => container.dispose());

  test('an event moves its key, as over a plain stream', () async {
    final subs = watch();
    await settle();
    expect(resumedFrom, [null]);
    server.current.event('a');
    await settle();
    expect(moves, {
      'a': [1],
    });
    expect(anyMoves, [1]);
    expect(container.read(feed.latest).value?.event, 'a');
    expect(container.read(feed.latest).value?.seq, 1);
    for (final sub in subs) {
      sub.close();
    }
  });

  test(
    'a gap moves every key once, at the reopen, without waiting for an event',
    () async {
      final subs = watch();
      await settle();
      server.current.event('a');
      await settle();
      moves.clear();
      anyMoves.clear();
      // No event ID: the reconnect cannot resume.
      server.current.drop();
      await settle();
      expect(moves, isEmpty, reason: 'a drop alone moves nothing');
      ticker().tick();
      await settle();
      expect(server.requests, hasLength(2));
      expect(server.current.lastEventId, isNull);
      expect(moves, {
        'a': [2],
        'b': [1],
        'c': [1],
      });
      expect(anyMoves, [2], reason: 'any moves by one');
      // The new log numbers from 1, and an event after the gap moves its key alone.
      server.current.event('b');
      await settle();
      expect(container.read(feed.latest).value?.seq, 1);
      expect(moves['b'], [1, 2]);
      expect(moves['a'], [2]);
      expect(moves['c'], [1]);
      for (final sub in subs) {
        sub.close();
      }
    },
  );

  test(
    'an event of the new connection that comes first moves its key once',
    () async {
      final subs = watch();
      await settle();
      server.current.drop();
      await settle();
      moves.clear();
      ticker().tick();
      // The event is written before anything settles: the key moves for the gap, and the event
      // of the new log is not counted twice.
      server.current.event('a');
      await settle();
      expect(moves['a'], hasLength(1));
      expect(moves['b'], [1]);
      expect(moves['c'], [1]);
      for (final sub in subs) {
        sub.close();
      }
    },
  );

  test('a reopen that resumed moves nothing', () async {
    final subs = watch();
    await settle();
    server.current.event('a', id: '1');
    await settle();
    moves.clear();
    anyMoves.clear();
    server.current.drop();
    await settle();
    ticker().tick();
    await settle();
    expect(server.current.lastEventId, '1');
    expect(moves, isEmpty);
    expect(anyMoves, isEmpty);
    // The server sends what was missed, and that moves its key as usual.
    server.current.event('c', id: '2');
    await settle();
    expect(moves, {
      'c': [1],
    });
    expect(container.read(feed.latest).value?.seq, 2);
    for (final sub in subs) {
      sub.close();
    }
  });

  test(
    'paused keys stop the reading; the tick closes it; a resume with an ID moves nothing',
    () async {
      final subs = watch();
      await settle();
      server.current.event('a', id: '1');
      await settle();
      moves.clear();
      for (final sub in subs) {
        sub.pause();
      }
      await settle();
      ticker().tick();
      await settle();
      expect(server.current.aborted, isFalse, reason: 'one tick only sees it');
      ticker().tick();
      await settle();
      expect(server.current.aborted, isTrue);
      expect(server.requests, hasLength(1));
      for (final sub in subs) {
        sub.resume();
      }
      await settle();
      expect(server.requests, hasLength(2));
      expect(server.current.lastEventId, '1');
      expect(moves, isEmpty);
      for (final sub in subs) {
        sub.close();
      }
    },
  );

  test(
    'a resume that cannot resume is a gap: every paused key moves once',
    () async {
      final subs = watch();
      await settle();
      server.current.event('a');
      await settle();
      moves.clear();
      for (final sub in subs) {
        sub.pause();
      }
      await settle();
      ticker()
        ..tick()
        ..tick();
      await settle();
      expect(server.current.aborted, isTrue);
      for (final sub in subs) {
        sub.resume();
      }
      await settle();
      expect(server.requests, hasLength(2));
      expect(moves, {
        'a': [2],
        'b': [1],
        'c': [1],
      });
      for (final sub in subs) {
        sub.close();
      }
    },
  );

  test(
    'with no key watched the connection stops reading, the tick closes it, a watch reopens it',
    () async {
      var subs = watch();
      await settle();
      server.current.event('a', id: '1');
      await settle();
      for (final sub in subs) {
        sub.close();
      }
      await settle();
      expect(
        server.current.aborted,
        isFalse,
        reason: 'a pause only stops reading',
      );
      ticker()
        ..tick()
        ..tick();
      await settle();
      expect(server.current.aborted, isTrue);
      expect(server.requests, hasLength(1));
      moves.clear();
      subs = watch();
      await settle();
      expect(server.requests, hasLength(2));
      expect(server.current.lastEventId, '1');
      expect(moves, isEmpty);
      for (final sub in subs) {
        sub.close();
      }
    },
  );

  test('a signal reconnects a waiting connection', () async {
    feed = live(rules: LiveRules(reconnectOn: [networkBack]));
    final keep = container.listen(networkBack, (_, _) {});
    final subs = watch();
    await settle();
    server.current.drop();
    await settle();
    container.read(networkBack.notifier).fire();
    await settle();
    expect(server.requests, hasLength(2));
    for (final sub in subs) {
      sub.close();
    }
    keep.close();
  });

  test('a rebuild opens a new connection with no ID, and is a gap', () async {
    feed = live(watchUser: true);
    final subs = watch();
    await settle();
    server.current.event('a', id: '7');
    await settle();
    moves.clear();
    container.read(user.notifier).signIn('grace');
    await settle();
    expect(server.connections.first.aborted, isTrue);
    expect(server.current.header('X-User'), 'grace');
    expect(resumedFrom, [null, null]);
    expect(server.current.lastEventId, isNull);
    expect(moves, {
      'a': [2],
      'b': [1],
      'c': [1],
    });
    for (final sub in subs) {
      sub.close();
    }
  });

  test('a key watched after a gap counts from there', () async {
    final first = container.listen(feed.any, (_, _) {});
    await settle();
    server.current.event('a');
    await settle();
    server.current.drop();
    await settle();
    ticker().tick();
    await settle();
    final subs = watch();
    await settle();
    expect(moves, isEmpty);
    server.current.event('a');
    await settle();
    expect(moves, {
      'a': [1],
    });
    for (final sub in subs) {
      sub.close();
    }
    first.close();
  });

  test(
    'a key watched after a gap starts from there when only latest stayed watched',
    () async {
      // A banner watches latest all the time ("live updates stopped"), so the connection keeps
      // reading, while the keep-alive log provider has no listener and holds the new log back.
      final banner = container.listen(feed.latest, (_, _) {});
      final page = container.listen(
        feed.topic<String>((e, k) => e == k)('a'),
        (_, _) {},
      );
      await settle();
      server.current.event('a');
      await settle();
      page.close();
      await settle();
      server.current.drop();
      await settle();
      ticker().tick();
      await settle();
      expect(server.requests, hasLength(2));
      final seen = <int>[];
      final again = container.listen(
        feed.topic<String>((e, k) => e == k)('b'),
        (_, next) => seen.add(next),
      );
      await settle();
      expect(seen, isEmpty, reason: 'the gap is older than this watcher');
      // The next event of the new log moves its key as usual.
      server.current.event('b');
      await settle();
      expect(seen, [1]);
      again.close();
      banner.close();
    },
  );

  test(
    'the first open after failed tries is a gap: what was sent meanwhile is lost',
    () async {
      server.respond(503);
      final subs = watch();
      await settle();
      expect(server.requests, hasLength(1));
      expect(moves, isEmpty);
      ticker().tick();
      await settle();
      expect(server.requests, hasLength(2));
      expect(server.current.isOpen, isTrue);
      expect(moves, {
        'a': [1],
        'b': [1],
        'c': [1],
      });
      expect(anyMoves, [1]);
      for (final sub in subs) {
        sub.close();
      }
    },
  );

  test('the first open at the first try is no gap', () async {
    final subs = watch();
    await settle();
    expect(server.requests, hasLength(1));
    expect(moves, isEmpty);
    expect(anyMoves, isEmpty);
    for (final sub in subs) {
      sub.close();
    }
  });

  test('a refusal is the error of latest and moves no key', () async {
    server.respond(403);
    final subs = watch();
    await settle();
    expect(container.read(feed.latest).error, isA<ServerEventsRefused>());
    expect(moves, isEmpty);
    expect(server.requests, hasLength(1));
    for (final sub in subs) {
      sub.close();
    }
  });

  test('the ticker looks after the connection', () async {
    final subs = watch();
    await settle();
    expect(ticker().trackedCount, 1);
    for (final sub in subs) {
      sub.close();
    }
  });

  test('the connection closes with the container', () async {
    final subs = watch();
    await settle();
    final connection = server.current;
    for (final sub in subs) {
      sub.close();
    }
    container.dispose();
    await settle();
    expect(connection.aborted, isTrue);
    container = ProviderContainer(overrides: streamTestOverrides());
  });

  test('no timer: open, drop, gap, pause and the end', () {
    fakeAsync((async) {
      container.dispose();
      container = ProviderContainer(overrides: streamTestOverrides());
      final subs = watch();
      void run() => async.elapse(Duration.zero);
      run();
      server.current.event('a');
      run();
      server.current.drop();
      run();
      expect(async.pendingTimers, isEmpty);
      ticker().tick();
      run();
      expect(moves['b'], [1], reason: 'the gap');
      for (final sub in subs) {
        sub.pause();
      }
      run();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(hours: 1));
      expect(server.requests, hasLength(2));
      expect(async.pendingTimers, isEmpty);
      for (final sub in subs) {
        sub.close();
      }
      container.dispose();
      run();
      expect(async.pendingTimers, isEmpty);
      container = ProviderContainer(overrides: streamTestOverrides());
    });
  });
}
