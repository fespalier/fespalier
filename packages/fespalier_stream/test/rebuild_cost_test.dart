// What an event costs the watchers it does not concern (since 0.21.0): nothing but a matcher
// call. Riverpod 3 pauses a stream provider while every one of its watchers rebuilds, so the
// core's stream is the observable: it is never paused by an event no watched key accepts.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:flutter_test/flutter_test.dart';

sealed class CoreEvent {
  const CoreEvent();
}

class OrderChanged extends CoreEvent {
  const OrderChanged(this.id);
  final int id;
}

/// A single-subscription source, like a generated stream, that counts the pauses Riverpod asks
/// of it.
final class PausingSource {
  late final controller = StreamController<CoreEvent>(
    sync: true,
    onPause: () => pauses++,
  );
  int pauses = 0;
}

void main() {
  late PausingSource core;
  late ChangeFeed<CoreEvent> feed;
  late ChangeTopic<CoreEvent, int> orderChanged;
  late Map<int, int> builds;
  late FutureProvider<int> Function(int id) order;
  late ProviderContainer container;
  late int matcherCalls;

  setUp(() {
    core = PausingSource();
    feed = ChangeFeed<CoreEvent>((ref) => core.controller.stream);
    matcherCalls = 0;
    orderChanged = feed.topic<int>((e, id) {
      matcherCalls++;
      return e is OrderChanged && e.id == id;
    });
    builds = {};
    order = FutureProvider.family<int, int>((ref, id) async {
      ref.watch(orderChanged(id));
      return builds[id] = (builds[id] ?? 0) + 1;
    }, retry: (_, _) => null).call;
    container = ProviderContainer();
    addTearDown(container.dispose);
    addTearDown(core.controller.close);
  });

  test('an event no watched key accepts rebuilds no revision', () async {
    for (var id = 0; id < 20; id++) {
      container.listen(order(id), (_, _) {});
    }
    await container.pump();
    for (var i = 0; i < 100; i++) {
      core.controller.add(OrderChanged(1000 + i));
      await container.pump();
    }
    expect(core.pauses, 0);
    expect(builds.values.toSet(), {1});
    expect(matcherCalls, 20 * 100); // once per watched key per event
  });

  test(
    'a burst is consumed in one turn while some watched key is not concerned',
    () async {
      for (var id = 0; id < 20; id++) {
        container.listen(order(id == 0 ? 42 : id), (_, _) {});
      }
      await container.pump();
      for (var i = 0; i < 1000; i++) {
        core.controller.add(OrderChanged(i.isEven ? 42 : 7));
      }
      await container.pump();
      expect(container.read(feed.latest).value?.seq, 1000);
      await container.pump();
      expect(builds[42], 2);
      expect(builds[7], 2);
      expect(builds[1], 1);
    },
  );

  test(
    'with no watcher the stream is held; a watcher of latest keeps it flowing',
    () async {
      final sub = container.listen(order(1), (_, _) {});
      await container.pump();
      sub.close();
      await container.pump();
      await Future<void>.delayed(Duration.zero);
      // Riverpod paused latest: the stream holds what the core sends until a topic is watched.
      expect(core.controller.isPaused, isTrue);

      // A "live updates stopped" banner: it watches latest, and only whether it failed.
      container.listen(feed.latest.select((v) => v.hasError), (_, _) {});
      await container.pump();
      expect(core.controller.isPaused, isFalse);

      container.listen(order(42), (_, _) {});
      await container.pump();
      for (var i = 0; i < 1000; i++) {
        core.controller.add(
          const OrderChanged(42),
        ); // the only watched key, every time
      }
      await container.pump();
      expect(container.read(feed.latest).value?.seq, 1000);
      await container.pump();
      expect(builds[42], 2);
    },
  );
}
