// ChangeBudget (since 0.21.0): a key of a budgeted topic moves at most once between two ticks of
// a provider the app fires. The first match after a tick moves at once; the rest wait for the
// next tick, which moves the key once if anything waited. Nothing is lost.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

sealed class CoreEvent {
  const CoreEvent();
}

class OrderChanged extends CoreEvent {
  const OrderChanged(this.id);
  final int id;
}

/// The tick an app would fire from its own timer; tests fire it by hand.
final tick = NotifierProvider<RefetchSignal, int>(RefetchSignal.new);

/// A tick on a timer, the way an app writes one (the timer is the app's, here the test's).
class TimerTick extends RefetchSignal {
  TimerTick(this.period);

  final Duration period;

  @override
  int build() {
    final timer = Timer.periodic(period, (_) => fire());
    ref.onDispose(timer.cancel);
    return 0;
  }
}

/// The tick of `docs/streaming.md` and of [ChangeBudget]'s dartdoc: the timer starts in `build`, stops
/// when the last active watcher is gone or paused, and starts again when one comes back.
class RecipeTick extends RefetchSignal {
  RecipeTick(this.onFire);

  final void Function() onFire;
  Timer? _timer;

  void _start() =>
      _timer ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
        onFire();
        fire();
      });

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  int build() {
    _start();
    ref.onCancel(_stop);
    ref.onResume(_start);
    ref.onDispose(_stop);
    return 0;
  }
}

/// The recipe as it was first written: the timer is cancelled on dispose only.
class DisposeOnlyTick extends RefetchSignal {
  DisposeOnlyTick(this.onFire);

  final void Function() onFire;

  @override
  int build() {
    final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      onFire();
      fire();
    });
    ref.onDispose(timer.cancel);
    return 0;
  }
}

void main() {
  late FakeChangeSource<CoreEvent> core;
  late ChangeFeed<CoreEvent> feed;
  late ChangeTopic<CoreEvent, int> orderChanged;
  late Map<int, int> builds;
  late FutureProvider<int> Function(int id) order;
  late ProviderContainer container;

  void fire() => container.read(tick.notifier).fire();

  setUp(() {
    core = FakeChangeSource<CoreEvent>(broadcast: false);
    feed = ChangeFeed<CoreEvent>((ref) => core.stream, name: 'core');
    orderChanged = feed.topic<int>(
      (e, id) => e is OrderChanged && e.id == id,
      budget: ChangeBudget(tick),
    );
    builds = {};
    order = FutureProvider.family<int, int>((ref, id) async {
      ref.watch(orderChanged(id));
      return builds[id] = (builds[id] ?? 0) + 1;
    }, retry: (_, _) => null).call;
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  test('the first match moves at once, the rest wait for the tick', () async {
    container.listen(order(42), (_, _) {});
    await container.pump();
    expect(builds[42], 1);

    core.emit(const OrderChanged(42));
    await container.pump();
    expect(builds[42], 2); // at once: nothing moved since the last tick

    for (var i = 0; i < 3; i++) {
      core.emit(const OrderChanged(42));
      await container.pump();
    }
    expect(builds[42], 2); // held

    fire();
    await container.pump();
    expect(builds[42], 3); // the tick moves it once

    fire();
    await container.pump();
    expect(builds[42], 3); // nothing held: a tick alone moves nothing

    core.emit(const OrderChanged(42));
    await container.pump();
    expect(builds[42], 4); // a quiet period again: at once
  });

  test('a held change is not lost when the core goes quiet', () async {
    container.listen(order(42), (_, _) {});
    await container.pump();
    core.emit(const OrderChanged(42));
    core.emit(const OrderChanged(42));
    await container.pump();
    expect(builds[42], 2);
    await container.pump();
    await container.pump();
    expect(builds[42], 2);
    fire();
    await container.pump();
    expect(builds[42], 3);
  });

  test('a tick moves only the keys that hold a change', () async {
    for (final id in [1, 2, 3]) {
      container.listen(order(id), (_, _) {});
    }
    await container.pump();
    core.emit(const OrderChanged(1));
    core.emit(const OrderChanged(2));
    await container.pump();
    core.emit(const OrderChanged(1));
    await container.pump();
    expect(builds, {1: 2, 2: 2, 3: 1});
    fire();
    await container.pump();
    expect(builds, {1: 3, 2: 2, 3: 1});
  });

  test('a key watched alone takes a whole burst in one turn', () async {
    container.listen(order(42), (_, _) {});
    await container.pump();
    for (var i = 0; i < 1000; i++) {
      core.emit(OrderChanged(i.isEven ? 42 : 7));
    }
    // The first match moves the key, and Riverpod pauses the stream for that one rebuild; the
    // rest of the burst is held, so it comes through in the same event-loop turn.
    await container.pump();
    await Future<void>.delayed(Duration.zero);
    expect(container.read(feed.latest).value?.seq, 1000);
    expect(builds[42], 2);
    fire();
    await container.pump();
    expect(builds[42], 3);
  });

  test(
    'a watcher paused through a tick rebuilds when it resumes, not at a later tick',
    () async {
      container.listen(feed.latest, (_, _) {});
      final sub = container.listen(order(42), (_, _) {});
      await container.pump();
      core.emit(const OrderChanged(42));
      await container.pump();
      expect(builds[42], 2);
      sub.pause();
      // Held: the key already moved since the last tick.
      core.emit(const OrderChanged(42));
      // The tick releases it while the watcher is paused: nothing rebuilds yet.
      fire();
      await container.pump();
      expect(builds[42], 2);
      sub.resume();
      await container.pump();
      // The key moved at the tick; the watcher takes the move as soon as it resumes.
      expect(builds[42], 3);
      // The next tick has nothing left to release.
      fire();
      await container.pump();
      expect(builds[42], 3);
    },
  );

  test('a restarted core still counts as a change under a budget', () async {
    final sources = <FakeChangeSource<CoreEvent>>[];
    final coreProvider = Provider<int>((ref) {
      sources.add(FakeChangeSource<CoreEvent>(broadcast: false));
      return sources.length;
    });
    final restartable = ChangeFeed<CoreEvent>(
      (ref) => sources[ref.watch(coreProvider) - 1].stream,
    );
    final topic = restartable.topic<int>(
      (e, id) => e is OrderChanged && e.id == id,
      budget: ChangeBudget(tick),
    );
    final values = <int>[];
    container.listen(topic(1), (_, next) => values.add(next));
    await container.pump();
    sources[0].emit(const OrderChanged(1));
    await container.pump();
    expect(values, [1]);
    container.invalidate(coreProvider);
    await container.pump();
    sources[1].emit(const OrderChanged(1));
    await container.pump();
    // A new stream is a change: the budget holds it until the tick.
    expect(values, [1]);
    fire();
    await container.pump();
    expect(values, [1, 2]);
  });

  group('the tick timer while the only budgeted key is paused (fake time)', () {
    /// A page watching one budgeted key, hidden (its watcher paused) for a minute, then shown.
    ({int firesWhilePaused, int buildsAfterResume}) hidden(
      NotifierProvider<RefetchSignal, int> Function(void Function() onFire)
      makeTick,
    ) {
      late int firesWhilePaused;
      late int buildsAfterResume;
      fakeAsync((async) {
        var fires = 0;
        final source = FakeChangeSource<CoreEvent>(broadcast: false);
        final feed = ChangeFeed<CoreEvent>((ref) => source.stream);
        final topic = feed.topic<int>(
          (e, id) => e is OrderChanged && e.id == id,
          budget: ChangeBudget(makeTick(() => fires++)),
        );
        var builds = 0;
        final data = FutureProvider.autoDispose<int>((ref) async {
          ref.watch(topic(42));
          return ++builds;
        }, retry: (_, _) => null);
        final container = ProviderContainer();
        final sub = container.listen(data, (_, _) {});
        async.elapse(const Duration(milliseconds: 1));
        source.emit(const OrderChanged(42)); // at once
        async.elapse(const Duration(milliseconds: 1));
        source.emit(const OrderChanged(42)); // held for the next tick
        async.elapse(const Duration(milliseconds: 1));
        expect(builds, 2);
        sub.pause(); // a route covers the page, or its tab is hidden
        async.elapse(const Duration(milliseconds: 1));
        final before = fires;
        async.elapse(const Duration(minutes: 1));
        firesWhilePaused = fires - before;
        sub.resume();
        async.elapse(const Duration(milliseconds: 250));
        buildsAfterResume = builds;
        container.dispose();
        async.flushTimers();
      });
      return (
        firesWhilePaused: firesWhilePaused,
        buildsAfterResume: buildsAfterResume,
      );
    }

    test(
      'a timer cancelled only on dispose keeps firing for a page nobody sees',
      () {
        final r = hidden(
          (onFire) => NotifierProvider.autoDispose<RefetchSignal, int>(
            () => DisposeOnlyTick(onFire),
          ),
        );
        expect(r.firesWhilePaused, greaterThan(500));
      },
    );

    test('the recipe fires nothing while paused, and still releases the held '
        'change shortly after the page is shown again', () {
      final r = hidden(
        (onFire) => NotifierProvider.autoDispose<RefetchSignal, int>(
          () => RecipeTick(onFire),
        ),
      );
      expect(r.firesWhilePaused, 0);
      expect(r.buildsAfterResume, 3);
    });
  });

  group('one simulated second of a busy core (fake time, 60 frames)', () {
    Future<({int dataBuilds, int widgetBuilds})> run(
      WidgetTester tester, {
      required int eventsPerSecond,
      ChangeBudget? budget,
    }) async {
      final source = FakeChangeSource<CoreEvent>(broadcast: false);
      final busy = ChangeFeed<CoreEvent>((ref) => source.stream);
      final topic = busy.topic<int>(
        (e, id) => e is OrderChanged && e.id == id,
        budget: budget,
      );
      var dataBuilds = 0;
      final data = FutureProvider<int>((ref) async {
        ref.watch(topic(42));
        return ++dataBuilds;
      }, retry: (_, _) => null);
      var widgetBuilds = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Consumer(
              builder: (context, ref, _) {
                widgetBuilds++;
                return Text('${ref.watch(data).value}');
              },
            ),
          ),
        ),
      );
      await tester.pump();
      dataBuilds = 0;
      widgetBuilds = 0;
      final gap = Duration(microseconds: 1000000 ~/ eventsPerSecond);
      for (var i = 0; i < eventsPerSecond; i++) {
        Timer(gap * i, () => source.emit(const OrderChanged(42)));
      }
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump(const Duration(microseconds: 16667));
      }
      await tester.pumpWidget(const SizedBox());
      return (dataBuilds: dataBuilds, widgetBuilds: widgetBuilds);
    }

    testWidgets('without a budget, data() reloads once per event', (
      tester,
    ) async {
      final r = await run(tester, eventsPerSecond: 5000);
      expect(r.dataBuilds, greaterThanOrEqualTo(5000));
      expect(r.widgetBuilds, lessThanOrEqualTo(61)); // widgets: once a frame
    });

    testWidgets('with a 16 ms tick, data() reloads at most once per tick', (
      tester,
    ) async {
      final timerTick = NotifierProvider.autoDispose<RefetchSignal, int>(
        () => TimerTick(const Duration(microseconds: 16667)),
      );
      final r = await run(
        tester,
        eventsPerSecond: 5000,
        budget: ChangeBudget(timerTick),
      );
      expect(r.dataBuilds, lessThanOrEqualTo(61));
      expect(r.dataBuilds, greaterThanOrEqualTo(59));
    });
  });

  group('a data() slower than the gap between its events', () {
    Future<int> settledFrames(WidgetTester tester, ChangeBudget? budget) async {
      final source = FakeChangeSource<CoreEvent>(broadcast: false);
      final busy = ChangeFeed<CoreEvent>((ref) => source.stream);
      final topic = busy.topic<int>(
        (e, id) => e is OrderChanged && e.id == id,
        budget: budget,
      );
      final data = FutureProvider<int>((ref) async {
        ref.watch(topic(42));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return 0;
      }, retry: (_, _) => null);
      var settled = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Consumer(
              builder: (context, ref, _) {
                final value = ref.watch(data);
                if (value.hasValue && !value.isLoading) settled++;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 10));
      settled = 0;
      for (var i = 0; i < 1000; i++) {
        Timer(
          Duration(milliseconds: i),
          () => source.emit(const OrderChanged(42)),
        );
      }
      var frames = 0;
      for (var frame = 0; frame < 60; frame++) {
        final before = settled;
        await tester.pump(const Duration(microseconds: 16667));
        if (settled > before) frames++;
      }
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const SizedBox());
      return frames;
    }

    testWidgets('never settles without a budget while the core is busy', (
      tester,
    ) async {
      expect(await settledFrames(tester, null), 0);
    });

    testWidgets('settles at the pace of the tick with a budget', (
      tester,
    ) async {
      final timerTick = NotifierProvider.autoDispose<RefetchSignal, int>(
        () => TimerTick(const Duration(milliseconds: 50)),
      );
      expect(
        await settledFrames(tester, ChangeBudget(timerTick)),
        greaterThanOrEqualTo(15),
      );
    });
  });
}
