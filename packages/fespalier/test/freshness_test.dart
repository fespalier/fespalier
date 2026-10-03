// Freshness (since 0.8.0): `freshData` ages a provider's value by `clock.now()`, which a
// widget test's fake async drives, so nothing here waits for real time or starts a timer.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/misc.dart' show Override;

/// Counts the loads; the value of the Nth load is N.
class Loads {
  var count = 0;
}

const fiveMinutes = Duration(minutes: 5);

FutureProvider<int> futureData(Loads loads, Freshness freshness) =>
    FutureProvider.autoDispose<int>(
      (ref) => freshData(ref, freshness, Future.value(++loads.count)),
    );

/// A provider of a value (no `Future`), as a synchronous data() makes.
Provider<int> syncData(Loads loads, Freshness freshness) =>
    Provider.autoDispose<int>(
      (ref) => freshData(ref, freshness, ++loads.count),
    );

/// A container with no retries, under a `ProviderScope` (so Riverpod refreshes on frames, as
/// in an app), disposed when the test ends.
Future<ProviderContainer> boot(
  WidgetTester tester, {
  List<Override> overrides = const [],
}) async {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: overrides,
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(scope(container, const SizedBox.shrink()));
  return container;
}

/// A load needs a frame to start and another to show: pump enough of them.
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump();
  }
}

/// Shows what [provider] has, and records every build in [painted].
class Probe extends ConsumerWidget {
  const Probe(this.provider, this.painted, {super.key});

  final ProviderListenable<AsyncValue<int>> provider;
  final List<String> painted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(provider);
    final text = value.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      data: (d) => 'v$d',
      loading: () => 'loading',
      error: (e, _) => 'error $e',
    );
    painted.add(text);
    return Text(text, textDirection: TextDirection.ltr);
  }
}

Widget scope(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(container: container, child: child);

Future<void> age(WidgetTester tester, Duration by) => tester.pump(by);

Future<void> resume(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await frames(tester);
}

void main() {
  group('freshData returns what it was given', () {
    testWidgets('the identical Future, value and Stream', (tester) async {
      final future = Future<int>.value(1);
      final controller = StreamController<int>();
      addTearDown(controller.close);
      const object = Object();
      Object? gotFuture;
      Object? gotValue;
      Object? gotStream;
      final stream = controller.stream;
      final container = await boot(tester);
      final a = FutureProvider.autoDispose<int>((ref) {
        gotFuture = freshData(
          ref,
          const Freshness(staleTime: fiveMinutes),
          future,
        );
        return future;
      });
      final b = Provider.autoDispose<Object>((ref) {
        gotValue = freshData<Object>(ref, const Freshness(), object);
        return object;
      });
      final c = StreamProvider.autoDispose<int>((ref) {
        gotStream = freshData(
          ref,
          const Freshness(staleTime: fiveMinutes, refetchOnResume: true),
          stream,
        );
        return stream;
      });
      container
        ..listen(a, (_, _) {})
        ..listen(b, (_, _) {})
        ..listen(c, (_, _) {});
      await frames(tester);
      expect(identical(gotFuture, future), isTrue);
      expect(identical(gotValue, object), isTrue);
      expect(identical(gotStream, stream), isTrue);
    });

    testWidgets('and a Stream never goes stale', (tester) async {
      var builds = 0;
      final controller = StreamController<int>();
      addTearDown(controller.close);
      final container = await boot(tester);
      final p = StreamProvider.autoDispose<int>((ref) {
        builds++;
        return freshData(
          ref,
          const Freshness(staleTime: Duration.zero, refetchOnResume: true),
          controller.stream,
        );
      });
      final keep = container.listen(p, (_, _) {});
      controller.add(1);
      await tester.pump(fiveMinutes);
      container.listen(p, (_, _) {}).close();
      await resume(tester);
      await frames(tester);
      expect(builds, 1);
      keep.close();
      await frames(tester);
    });
  });

  group('staleTime and a new listener', () {
    testWidgets('a listener before staleTime does not load again', (
      tester,
    ) async {
      final loads = Loads();
      final p = futureData(loads, const Freshness(staleTime: fiveMinutes));
      final container = await boot(tester);
      final keep = container.listen(p, (_, _) {});
      await frames(tester);
      await age(tester, const Duration(minutes: 4));
      final painted = <String>[];
      await tester.pumpWidget(scope(container, Probe(p, painted)));
      await frames(tester);
      expect(loads.count, 1);
      expect(painted, ['v1']);
      keep.close();
      await frames(tester);
    });

    testWidgets(
      'a listener after it paints the stale value, then loads again',
      (tester) async {
        final loads = Loads();
        final p = futureData(loads, const Freshness(staleTime: fiveMinutes));
        final container = await boot(tester);
        final keep = container.listen(p, (_, _) {});
        await frames(tester);
        await age(tester, const Duration(minutes: 6));
        final painted = <String>[];
        await tester.pumpWidget(scope(container, Probe(p, painted)));
        // The stale value is in the first frame.
        expect(painted.first, 'v1');
        expect(find.text('v1'), findsOneWidget);
        await frames(tester);
        expect(loads.count, 2);
        expect(find.text('v2'), findsOneWidget);
        // Never a blank frame in between.
        expect(painted.toSet().difference({'v1', 'v2'}), isEmpty);
        keep.close();
        await frames(tester);
      },
    );

    testWidgets('a value loaded again is fresh again', (tester) async {
      final loads = Loads();
      final p = futureData(loads, const Freshness(staleTime: fiveMinutes));
      final container = await boot(tester);
      final keep = container.listen(p, (_, _) {});
      await frames(tester);
      await age(tester, const Duration(minutes: 6));
      container.listen(p, (_, _) {}).close();
      await frames(tester);
      expect(loads.count, 2);
      // A reader a minute after the reload does not load a third time.
      await age(tester, const Duration(minutes: 1));
      container.listen(p, (_, _) {}).close();
      await frames(tester);
      expect(loads.count, 2);
      keep.close();
      await frames(tester);
    });

    testWidgets('no staleTime never loads again by age', (tester) async {
      final loads = Loads();
      final p = futureData(loads, const Freshness(refetchOnResume: true));
      final container = await boot(tester);
      final keep = container.listen(p, (_, _) {});
      await frames(tester);
      await age(tester, const Duration(days: 30));
      container.listen(p, (_, _) {}).close();
      await frames(tester);
      expect(loads.count, 1);
      keep.close();
      await frames(tester);
    });

    testWidgets('a synchronous value ages too, and a Duration.zero one is not '
        'loaded again by the listener that created it', (tester) async {
      final loads = Loads();
      final p = syncData(loads, const Freshness(staleTime: Duration.zero));
      final container = await boot(tester);
      final keep = container.listen(p, (_, _) {});
      await frames(tester);
      expect(loads.count, 1);
      await age(tester, const Duration(seconds: 1));
      container.listen(p, (_, _) {}).close();
      await frames(tester);
      expect(loads.count, 2);
      keep.close();
      await frames(tester);
    });

    testWidgets('an error is never stale', (tester) async {
      var runs = 0;
      final p = FutureProvider.autoDispose<int>(
        (ref) => freshData(
          ref,
          const Freshness(staleTime: Duration(minutes: 1)),
          Future<int>.error(Exception('boom ${++runs}')),
        ),
      );
      final container = await boot(tester);
      final keep = container.listen(p, (_, _) {});
      await frames(tester);
      await age(tester, const Duration(hours: 1));
      container.listen(p, (_, _) {}).close();
      await frames(tester);
      expect(runs, 1);
      keep.close();
      await frames(tester);
    });

    testWidgets('a slow load is not stale while it is loading', (tester) async {
      var runs = 0;
      final completer = Completer<int>();
      final p = FutureProvider.autoDispose<int>(
        (ref) => freshData(ref, const Freshness(staleTime: Duration.zero), () {
          runs++;
          return completer.future;
        }()),
      );
      final container = await boot(tester);
      final keep = container.listen(p, (_, _) {});
      await age(tester, const Duration(hours: 1));
      container.listen(p, (_, _) {}).close();
      await frames(tester);
      expect(runs, 1);
      completer.complete(1);
      await frames(tester);
      keep.close();
      await frames(tester);
    });
  });

  group('an invalidation', () {
    // What an action's `invalidates` does: staleTime is for reads, never for this.
    testWidgets('loads again at once, however long the staleTime', (
      tester,
    ) async {
      final loads = Loads();
      final p = futureData(
        loads,
        const Freshness(staleTime: Duration(days: 1)),
      );
      final container = await boot(tester);
      await tester.pumpWidget(scope(container, Probe(p, <String>[])));
      await frames(tester);
      expect(loads.count, 1);
      expect(find.text('v1'), findsOneWidget);
      container.invalidate(p);
      await frames(tester);
      expect(loads.count, 2);
      expect(find.text('v2'), findsOneWidget);
      container.invalidate(p);
      await frames(tester);
      expect(loads.count, 3);
    });

    testWidgets('of a synchronous value too, and of a cached one', (
      tester,
    ) async {
      final loads = Loads();
      final p = syncData(loads, const Freshness(staleTime: Duration(days: 1)));
      final container = await boot(tester);
      final keep = container.listen(p, (_, _) {});
      await frames(tester);
      container.invalidate(p);
      await frames(tester);
      expect(loads.count, 2);
      keep.close();
      await frames(tester);

      var cachedLoads = 0;
      final c = cachedData<int>(
        (ref) => ++cachedLoads,
        cache: DataCache<int>(encode: (v) => '$v', decode: int.parse),
        name: 'c',
        freshness: const Freshness(staleTime: Duration(days: 1)),
      );
      final keepCached = container.listen(c, (_, _) {});
      await frames(tester);
      container.invalidate(c);
      await frames(tester);
      expect(cachedLoads, 2);
      keepCached.close();
      await frames(tester);
    });
  });

  group('a listener coming back', () {
    testWidgets('a page uncovered (TickerMode on again) after staleTime '
        'paints the stale value and loads again', (tester) async {
      final loads = Loads();
      final p = futureData(loads, const Freshness(staleTime: fiveMinutes));
      final container = await boot(tester);
      final enabled = ValueNotifier(true);
      addTearDown(enabled.dispose);
      final painted = <String>[];
      await tester.pumpWidget(
        scope(
          container,
          ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (_, on, _) =>
                TickerMode(enabled: on, child: Probe(p, painted)),
          ),
        ),
      );
      await frames(tester);
      expect(loads.count, 1);
      enabled.value = false;
      await frames(tester);
      await age(tester, const Duration(minutes: 6));
      expect(loads.count, 1);
      painted.clear();
      enabled.value = true;
      await frames(tester);
      expect(painted.first, 'v1');
      await frames(tester);
      expect(loads.count, 2);
      expect(find.text('v2'), findsOneWidget);
    });

    testWidgets('and one uncovered before staleTime does not', (tester) async {
      final loads = Loads();
      final p = futureData(loads, const Freshness(staleTime: fiveMinutes));
      final container = await boot(tester);
      final enabled = ValueNotifier(true);
      addTearDown(enabled.dispose);
      await tester.pumpWidget(
        scope(
          container,
          ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (_, on, _) =>
                TickerMode(enabled: on, child: Probe(p, <String>[])),
          ),
        ),
      );
      await frames(tester);
      enabled.value = false;
      await frames(tester);
      await age(tester, const Duration(minutes: 1));
      enabled.value = true;
      await frames(tester);
      await frames(tester);
      expect(loads.count, 1);
    });
  });

  group('resume', () {
    testWidgets('within staleTime does nothing, after it loads again', (
      tester,
    ) async {
      final loads = Loads();
      final p = futureData(
        loads,
        const Freshness(staleTime: fiveMinutes, refetchOnResume: true),
      );
      final container = await boot(tester);
      await tester.pumpWidget(scope(container, Probe(p, <String>[])));
      await frames(tester);
      await age(tester, const Duration(minutes: 1));
      await resume(tester);
      expect(loads.count, 1);
      await age(tester, const Duration(minutes: 5));
      await resume(tester);
      await frames(tester);
      expect(loads.count, 2);
      expect(find.text('v2'), findsOneWidget);
    });

    testWidgets('with no staleTime always loads again', (tester) async {
      final loads = Loads();
      final p = futureData(loads, const Freshness(refetchOnResume: true));
      final container = await boot(tester);
      await tester.pumpWidget(scope(container, Probe(p, <String>[])));
      await frames(tester);
      await resume(tester);
      await frames(tester);
      expect(loads.count, 2);
      await resume(tester);
      await frames(tester);
      expect(loads.count, 3);
    });

    testWidgets('without refetchOnResume does nothing', (tester) async {
      final loads = Loads();
      final p = futureData(loads, const Freshness(staleTime: fiveMinutes));
      final container = await boot(tester);
      await tester.pumpWidget(scope(container, Probe(p, <String>[])));
      await frames(tester);
      await age(tester, const Duration(hours: 1));
      await resume(tester);
      await frames(tester);
      expect(loads.count, 1);
      expect(container.exists(appResumeSignal), isFalse);
    });

    testWidgets('a signal while the page is hidden loads when it is shown', (
      tester,
    ) async {
      final loads = Loads();
      final p = futureData(loads, const Freshness(refetchOnResume: true));
      final container = await boot(tester);
      final enabled = ValueNotifier(true);
      addTearDown(enabled.dispose);
      await tester.pumpWidget(
        scope(
          container,
          ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (_, on, _) =>
                TickerMode(enabled: on, child: Probe(p, <String>[])),
          ),
        ),
      );
      await frames(tester);
      enabled.value = false;
      await frames(tester);
      await resume(tester);
      await frames(tester);
      enabled.value = true;
      await frames(tester);
      await frames(tester);
      expect(loads.count, 2);
      expect(find.text('v2'), findsOneWidget);
    });

    testWidgets('the lifecycle listener goes with the last fresh provider', (
      tester,
    ) async {
      final loads = Loads();
      final p = futureData(loads, const Freshness(refetchOnResume: true));
      final container = await boot(tester);
      final keep = container.listen(p, (_, _) {});
      await frames(tester);
      expect(container.exists(appResumeSignal), isTrue);
      keep.close();
      await frames(tester);
      await frames(tester);
      expect(container.exists(p), isFalse);
      expect(container.exists(appResumeSignal), isFalse);
      // No listener is left to fire: a resume is a no-op.
      await resume(tester);
      expect(loads.count, 1);
    });
  });

  group('reconnect', () {
    testWidgets('follows the same rule as resume', (tester) async {
      final loads = Loads();
      final p = futureData(
        loads,
        const Freshness(staleTime: fiveMinutes, refetchOnReconnect: true),
      );
      final container = await boot(tester);
      await tester.pumpWidget(scope(container, Probe(p, <String>[])));
      await frames(tester);
      await age(tester, const Duration(minutes: 1));
      container.read(reconnectSignal.notifier).fire();
      await frames(tester);
      expect(loads.count, 1);
      await age(tester, const Duration(minutes: 5));
      container.read(reconnectSignal.notifier).fire();
      await frames(tester);
      expect(loads.count, 2);
    });

    testWidgets('does nothing without refetchOnReconnect', (tester) async {
      final loads = Loads();
      final p = futureData(loads, const Freshness(refetchOnResume: true));
      final container = await boot(tester);
      await tester.pumpWidget(scope(container, Probe(p, <String>[])));
      await frames(tester);
      container.read(reconnectSignal.notifier).fire();
      await frames(tester);
      expect(loads.count, 1);
    });

    testWidgets('an overridden signal is what fires it', (tester) async {
      final loads = Loads();
      final p = futureData(loads, const Freshness(refetchOnReconnect: true));
      final online = StreamController<bool>();
      addTearDown(online.close);
      final container = await boot(
        tester,
        overrides: [
          reconnectSignal.overrideWith(() => _StreamSignal(online.stream)),
        ],
      );
      await tester.pumpWidget(scope(container, Probe(p, <String>[])));
      await frames(tester);
      online
        ..add(false)
        ..add(true);
      await frames(tester);
      await frames(tester);
      expect(loads.count, 2);
    });
  });
}

/// A reconnect signal over a `Stream<bool>` the app owns: fires on offline to online.
class _StreamSignal extends RefetchSignal {
  _StreamSignal(this.online);

  final Stream<bool> online;

  @override
  int build() {
    var was = true;
    final subscription = online.listen((now) {
      if (now && !was) fire();
      was = now;
    });
    ref.onDispose(subscription.cancel);
    return 0;
  }
}
