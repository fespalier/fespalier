import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_frb/fespalier_frb.dart';
import 'package:fespalier_frb/testing.dart';
import 'package:flutter_test/flutter_test.dart';

sealed class CoreEvent {
  const CoreEvent();
}

class OrderChanged extends CoreEvent {
  const OrderChanged(this.id);
  final int id;
}

class CartCleared extends CoreEvent {
  const CartCleared();
}

/// Riverpod may deliver a burst to a dependent in one rebuild or in several: pump until nothing
/// is left.
Future<void> settle(ProviderContainer container) async {
  for (var i = 0; i < 400; i++) {
    await container.pump();
  }
}

void main() {
  for (final broadcast in [true, false]) {
    group(broadcast ? 'a broadcast stream' : 'a single-subscription stream', () {
      late FakeChangeSource<CoreEvent> core;
      late ChangeFeed<CoreEvent> feed;
      late ChangeTopic<CoreEvent, int> orderChanged;
      late Map<int, int> builds;
      late ProviderContainer container;

      /// A data provider per order that counts its builds, like a data.dart would.
      late FutureProvider<String> Function(int id) order;

      setUp(() {
        core = FakeChangeSource(broadcast: broadcast);
        feed = ChangeFeed<CoreEvent>((ref) => core.stream, name: 'core');
        orderChanged = feed.topic<int>(
          (e, id) => e is OrderChanged && e.id == id,
        );
        builds = {};
        order = FutureProvider.family<String, int>((ref, id) async {
          ref.watch(orderChanged(id));
          builds[id] = (builds[id] ?? 0) + 1;
          return 'order $id #${builds[id]}';
        }).call;
        container = ProviderContainer();
        addTearDown(container.dispose);
      });

      test(
        'a provider watching a topic rebuilds on a matching event only',
        () async {
          container.listen(order(42), (_, _) {});
          container.listen(order(7), (_, _) {});
          await container.pump();
          expect(builds, {42: 1, 7: 1});

          core.emit(const OrderChanged(42));
          await container.pump();
          expect(builds, {42: 2, 7: 1});

          core.emit(const OrderChanged(99));
          core.emit(const CartCleared());
          await container.pump();
          expect(builds, {42: 2, 7: 1});
          expect(await container.read(order(42).future), 'order 42 #2');
        },
      );

      test('two equal events are two rebuilds', () async {
        container.listen(order(42), (_, _) {});
        await container.pump();
        core.emit(const OrderChanged(42));
        await container.pump();
        core.emit(const OrderChanged(42));
        await container.pump();
        expect(builds[42], 3);
      });

      test('events that arrive together rebuild once', () async {
        container.listen(order(42), (_, _) {});
        await container.pump();
        core.emit(const OrderChanged(42));
        core.emit(const OrderChanged(42));
        await container.pump();
        expect(builds[42], 2);
      });

      test('a matching event inside a burst is not lost', () async {
        container.listen(
          feed.latest,
          (_, _) {},
        ); // latest active: the burst collapses
        container.listen(order(42), (_, _) {});
        await container.pump();
        core.emit(const OrderChanged(7));
        core.emit(const OrderChanged(42));
        core.emit(const OrderChanged(7));
        await settle(container);
        expect(builds[42], 2);
        expect(builds[7] ?? 0, 0);
      });

      test('a paused watcher catches up on every event it missed', () async {
        container.listen(feed.latest, (_, _) {});
        final sub = container.listen(order(42), (_, _) {});
        await container.pump();
        sub.pause();
        core.emit(const OrderChanged(42));
        core.emit(const OrderChanged(7));
        await settle(container);
        expect(builds[42], 1);
        sub.resume();
        await settle(container);
        expect(builds[42], 2);
      });

      test('any counts every event of a burst', () async {
        container.listen(feed.latest, (_, _) {});
        final seen = <int>[];
        container.listen(feed.any, (_, next) => seen.add(next));
        await container.pump();
        core.emit(const OrderChanged(1));
        core.emit(const OrderChanged(2));
        core.emit(const CartCleared());
        await settle(container);
        expect(seen.last, 3);
      });

      test('a match before a burst longer than the log is not lost', () async {
        container.listen(feed.latest, (_, _) {});
        container.listen(order(42), (_, _) {});
        await container.pump();
        core.emit(const OrderChanged(42));
        for (var i = 0; i < changeLogCapacity + 10; i++) {
          core.emit(const OrderChanged(7));
        }
        await settle(container);
        expect(builds[42], 2);
      });

      test('one subscription serves any number of topics', () async {
        final cart = feed.topic<Null>((e, _) => e is CartCleared);
        for (var id = 0; id < 20; id++) {
          container.listen(order(id), (_, _) {});
        }
        container.listen(cart(null), (_, _) {});
        container.listen(feed.any, (_, _) {});
        await container.pump();
        expect(core.listenCount, 1);
        expect(core.cancelCount, 0);
      });

      test(
        'the subscription is closed when the container is disposed',
        () async {
          container.listen(order(1), (_, _) {});
          await container.pump();
          expect(core.hasListener, isTrue);
          container.dispose();
          expect(core.hasListener, isFalse);
          expect(core.cancelCount, 1);
        },
      );

      test('nothing is subscribed until something watches', () {
        expect(core.listenCount, 0);
        container.read(feed.latest);
        expect(core.listenCount, 1);
      });

      test(
        'a watcher that starts late does not count the events before it',
        () async {
          container.listen(feed.latest, (_, _) {});
          core.emit(const OrderChanged(42));
          await container.pump();
          container.listen(order(42), (_, _) {});
          await container.pump();
          expect(builds[42], 1);
          core.emit(const OrderChanged(42));
          await container.pump();
          expect(builds[42], 2);
        },
      );

      test('any counts every event', () async {
        final seen = <int>[];
        container.listen(feed.any, (_, next) => seen.add(next));
        await container.pump();
        core.emit(const OrderChanged(1));
        await container.pump();
        core.emit(const CartCleared());
        await container.pump();
        expect(seen, [1, 2]);
        expect(identical(feed.any, feed.any), isTrue);
      });

      test('a stream error is kept in latest and rebuilds nobody', () async {
        container.listen(order(42), (_, _) {});
        await container.pump();
        core.emitError(StateError('core stopped'));
        await container.pump();
        expect(container.read(feed.latest).hasError, isTrue);
        expect(builds[42], 1);
        core.emit(const OrderChanged(42));
        await container.pump();
        expect(builds[42], 2);
      });
    });
  }

  test(
    'a topic of a key nobody watches costs nothing: its revision is disposed',
    () async {
      final core = FakeChangeSource<CoreEvent>();
      final feed = ChangeFeed<CoreEvent>((ref) => core.stream);
      final topic = feed.topic<int>((e, id) => e is OrderChanged && e.id == id);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final sub = container.listen(topic(1), (_, _) {});
      await container.pump();
      sub.close();
      await container.pump();
      core.emit(const OrderChanged(1));
      await container.pump();
      // Watched again: the event before this watch is history.
      final values = <int>[];
      container.listen(topic(1), (_, next) => values.add(next));
      await container.pump();
      expect(values, isEmpty);
    },
  );

  test('each container opens its own stream', () async {
    final sources = <FakeChangeSource<CoreEvent>>[];
    final feed = ChangeFeed<CoreEvent>((ref) {
      final source = FakeChangeSource<CoreEvent>(broadcast: false);
      sources.add(source);
      return source.stream;
    });
    final a = ProviderContainer();
    final b = ProviderContainer();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    a.read(feed.latest);
    b.read(feed.latest);
    expect(sources, hasLength(2));
  });

  test(
    'a core that is restarted reopens the stream and numbering starts over',
    () async {
      final sources = <FakeChangeSource<CoreEvent>>[];
      final core = Provider<int>((ref) {
        sources.add(FakeChangeSource<CoreEvent>(broadcast: false));
        return sources.length;
      });
      final feed = ChangeFeed<CoreEvent>(
        (ref) => sources[ref.watch(core) - 1].stream,
      );
      final topic = feed.topic<int>((e, id) => e is OrderChanged && e.id == id);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final values = <int>[];
      container.listen(topic(1), (_, next) => values.add(next));
      await container.pump();
      sources[0].emit(const OrderChanged(1));
      await container.pump();
      expect(values, [1]);

      container.invalidate(core);
      await container.pump();
      expect(sources, hasLength(2));
      expect(sources[0].hasListener, isFalse);
      sources[1].emit(
        const OrderChanged(1),
      ); // numbered 1 again: still a change
      await container.pump();
      expect(values, [1, 2]);
    },
  );

  test(
    'a change made by hand moves a matching topic, once per change',
    () async {
      final feed = ChangeFeed<CoreEvent>((ref) => const Stream.empty());
      final topic = feed.topic<int>((e, id) => e is OrderChanged && e.id == id);
      final handMade = StreamController<Change<CoreEvent>>();
      addTearDown(handMade.close);
      final container = ProviderContainer(
        overrides: [feed.latest.overrideWith((ref) => handMade.stream)],
      );
      addTearDown(container.dispose);
      final values = <int>[];
      container.listen(topic(42), (_, next) => values.add(next));
      await container.pump();
      handMade.add(const Change(OrderChanged(7), 1));
      await settle(container);
      handMade.add(const Change(OrderChanged(42), 2));
      await settle(container);
      handMade.add(Change(const OrderChanged(42), 3));
      await settle(container);
      expect(values, [1, 2]);
    },
  );

  group('InvalidationTable', () {
    final order = FutureProvider.family<String, int>((ref, id) async => '$id');
    final cart = FutureProvider<String>((ref) async => 'cart');
    final orders = FutureProvider<String>((ref) async => 'orders');

    final table = InvalidationTable<CoreEvent>([
      InvalidationRule.on<OrderChanged, CoreEvent>(
        (e) => [order(e.id), orders],
      ),
      InvalidationRule.on<CartCleared, CoreEvent>((_) => [cart, orders]),
    ]);

    test('invalidates exactly the listed providers, once each', () {
      final invalidated = <ProviderOrFamily>[];
      expect(table.apply(const OrderChanged(42), invalidated.add), 2);
      expect(invalidated, [order(42), orders]);
      invalidated.clear();
      expect(table.apply(const CartCleared(), invalidated.add), 2);
      expect(invalidated, [cart, orders]);
    });

    test('a provider two rules list is invalidated once', () {
      final twice = InvalidationTable<CoreEvent>([
        InvalidationRule((_) => true, (_) => [orders]),
        InvalidationRule((_) => true, (_) => [orders, cart]),
      ]);
      final invalidated = <ProviderOrFamily>[];
      expect(twice.apply(const CartCleared(), invalidated.add), 2);
      expect(invalidated, [orders, cart]);
    });

    test('an event no rule accepts invalidates nothing', () {
      final none = InvalidationTable<CoreEvent>([
        InvalidationRule((e) => e is CartCleared, (_) => [cart]),
      ]);
      final invalidated = <ProviderOrFamily>[];
      expect(none.apply(const OrderChanged(1), invalidated.add), 0);
      expect(invalidated, isEmpty);
    });

    test('it drives a container: the listed provider loads again', () async {
      var loads = 0;
      final counted = FutureProvider<int>((ref) async => ++loads);
      final t = InvalidationTable<CoreEvent>([
        InvalidationRule.on<OrderChanged, CoreEvent>((_) => [counted]),
      ]);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(counted, (_, _) {});
      await container.pump();
      expect(loads, 1);
      t.apply(const OrderChanged(1), container.invalidate);
      await container.pump();
      expect(loads, 2);
    });
  });
}
