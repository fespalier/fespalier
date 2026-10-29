// How often Riverpod 3 pauses a feed's source while the providers that watch its topics rebuild.
// Riverpod pauses a stream provider when every one of its watchers is rebuilding at once (each
// invalidated provider pauses its subscriptions until it is built again), and the source sees a
// `pause` then a `resume`. A live connection that closed on every pause would reconnect on every
// such burst, so the counts here are the reason a paused stream only stops reading.
//
// 50 keys are watched; 200 events arrive, all in one turn or one per turn, each about one key or
// about every key. The counts are deterministic (Riverpod's scheduler and the source are driven by
// the test alone); each test pins the count measured with riverpod 3.4.3, written next to it, as
// its bounds: the measured value is the lower end where a pause must happen, and the upper end has
// 2x slack (a Riverpod patch may add a pause or two, a Riverpod that pauses far more, or no longer
// at all, fails here). The case that is never paused is exact.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:flutter_test/flutter_test.dart';

const keys = 50;
const events = 200;

/// An event about one key, or about every key (`id` null).
final class Changed {
  const Changed(this.id);
  final int? id;
}

final class Churn {
  int pauses = 0;
  int resumes = 0;
  int builds = 0;
  int? lastSeq;
  bool stillPaused = false;

  @override
  String toString() =>
      'pauses $pauses, resumes $resumes, builds $builds, last seq $lastSeq, '
      'paused at the end $stillPaused';
}

/// Runs one burst and counts what the source saw.
Future<Churn> run({required bool oneTurn, required bool everyKey}) async {
  final churn = Churn();
  final controller = StreamController<Changed>(
    sync: true,
    onPause: () => churn.pauses++,
    onResume: () => churn.resumes++,
  );
  final feed = ChangeFeed<Changed>((ref) => controller.stream);
  final changed = feed.topic<int>((e, id) => e.id == null || e.id == id);
  final data = FutureProvider.family<int, int>((ref, id) async {
    ref.watch(changed(id));
    return ++churn.builds;
  }, retry: (_, _) => null);
  final container = ProviderContainer();
  for (var id = 0; id < keys; id++) {
    container.listen(data(id), (_, _) {});
  }
  await container.pump();
  churn.builds = 0;

  for (var i = 0; i < events; i++) {
    controller.add(Changed(everyKey ? null : i % keys));
    if (!oneTurn) await container.pump();
  }
  // Let the rebuilds and the resumed deliveries settle.
  for (var i = 0; i < 2 * events && controller.isPaused; i++) {
    await container.pump();
  }
  await container.pump();
  churn.lastSeq = container.read(feed.latest).value?.seq;
  churn.stillPaused = controller.isPaused;

  // Counted before the disposal, which pauses the source once more on its way out.
  final counted = Churn()
    ..pauses = churn.pauses
    ..resumes = churn.resumes
    ..builds = churn.builds
    ..lastSeq = churn.lastSeq
    ..stillPaused = churn.stillPaused;
  container.dispose();
  await controller.close();
  return counted;
}

void main() {
  // Every pause is followed by its resume, and the source is not left paused: a pause is a
  // stall, never an end.
  void settled(Churn churn) {
    expect(churn.lastSeq, events, reason: '$churn');
    expect(churn.resumes, churn.pauses, reason: '$churn');
    expect(churn.stillPaused, isFalse, reason: '$churn');
  }

  test('one key per event, one per turn: never paused', () async {
    final churn = await run(oneTurn: false, everyKey: false);
    settled(churn);
    expect(churn.pauses, 0, reason: '$churn');
  });

  // Measured with riverpod 3.4.3: 51 pauses (keys + 1). The first 50 events reach every key
  // before any rebuild, so every watcher is rebuilding at once. Bounded at 2x the measured count.
  test(
    'one key per event, all in one turn: paused, about once per key',
    () async {
      final churn = await run(oneTurn: true, everyKey: false);
      settled(churn);
      expect(
        churn.pauses,
        inInclusiveRange(1, 2 * (keys + 1)),
        reason: '$churn',
      );
    },
  );

  // Measured with riverpod 3.4.3: 51 pauses (keys + 1). Bounded at 2x the measured count.
  test(
    'every key per event, all in one turn: paused, about once per key',
    () async {
      final churn = await run(oneTurn: true, everyKey: true);
      settled(churn);
      expect(
        churn.pauses,
        inInclusiveRange(1, 2 * (keys + 1)),
        reason: '$churn',
      );
    },
  );

  // Measured with riverpod 3.4.3: 10200 pauses, keys + 1 per event: one when the last watcher
  // is invalidated, then a resume and a pause as each watcher but the last is built again.
  // Bounded at 2x the measured count.
  test(
    'every key per event, one per turn: paused at least once per event',
    () async {
      final churn = await run(oneTurn: false, everyKey: true);
      settled(churn);
      expect(
        churn.pauses,
        inInclusiveRange(events, 2 * (keys + 1) * events),
        reason: '$churn',
      );
    },
  );
}
