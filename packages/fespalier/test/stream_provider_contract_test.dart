// What Riverpod 3 does with a stream that a streaming data provider relies on, pinned so that an
// upgrade that changes it fails here rather than in an app:
//
// - a `StreamProvider` whose stream emits an error retries with a `Timer` by default (200 ms, then
//   doubling) and runs its body again, even when an event arrives in between; with
//   `retry: (_, _) => null` it keeps the error, starts no timer, and a later event of the same
//   stream still arrives (the subscription is not `cancelOnError`);
// - a widget under `TickerMode(enabled: false)` pauses the source's subscription (its `onPause`),
//   and enabling it again resumes it (`onResume`), without cancelling it;
// - a `StreamNotifier` is created once per element: its fields outlive a rebuild that a
//   `ref.watch` causes, and not a disposal.
//
// Read in riverpod 3.4.3: `ElementWithFuture.handleStream` and `_handleAsync` (the mixin) and
// `ProviderElement.triggerRetry` (`lib/src/core/element.dart`), `ProviderContainer.defaultRetry`, and
// `$ClassProviderElement.create` (`classListenable.result ??=`); `TickerMode` in flutter_riverpod
// 3.4.3's `ConsumerStatefulElement._updateTickerMode`.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A source that hands out a new single-subscription stream per open (a stream provider whose
/// body runs again listens again) and counts what Riverpod does to each.
final class Source {
  final List<StreamController<int>> opened = [];
  int pauses = 0;
  int resumes = 0;
  int cancels = 0;

  Stream<int> open() {
    final controller = StreamController<int>(
      sync: true,
      onPause: () => pauses++,
      onResume: () => resumes++,
      onCancel: () => cancels++,
    );
    opened.add(controller);
    return controller.stream;
  }

  StreamController<int> get last => opened.last;
}

/// A notifier whose fields are what a live feed would keep (a `Last-Event-ID`).
final class Remembering extends StreamNotifier<int> {
  Remembering(this.source, this.signal);

  final Source source;
  final ProviderListenable<int> signal;

  /// Set by the stream's events, read back after a rebuild.
  int? lastSeen;
  int builds = 0;

  @override
  Stream<int> build() {
    ref.watch(signal);
    builds++;
    return source.open().map((value) => lastSeen = value);
  }
}

void main() {
  group('a StreamProvider whose stream emits an error', () {
    test(
      'with the default retry: a Timer of 200 ms, then the body runs again',
      () {
        fakeAsync((async) {
          final source = Source();
          var runs = 0;
          final provider = StreamProvider.autoDispose<int>((ref) {
            runs++;
            return source.open();
          });
          final container = ProviderContainer();
          final sub = container.listen(provider, (_, _) {});
          async.flushMicrotasks();
          expect(runs, 1);

          source.last.addError(Exception('the connection dropped'));
          async.flushMicrotasks();

          final state = container.read(provider);
          // Retrying: loading, with the error, and a timer pending.
          expect(state.isLoading, isTrue);
          expect(state.hasError, isTrue);
          expect(state.retrying, isTrue);
          expect(async.pendingTimers, hasLength(1));
          expect(
            async.pendingTimers.single.duration,
            const Duration(milliseconds: 200),
          );

          async.elapse(const Duration(milliseconds: 199));
          expect(runs, 1);
          async.elapse(const Duration(milliseconds: 1));
          async.flushMicrotasks();
          // The body ran again: a new stream, and the old subscription is cancelled.
          expect(runs, 2);
          expect(source.opened, hasLength(2));
          expect(source.cancels, 1);

          // A second error waits twice as long.
          source.last.addError(Exception('dropped again'));
          async.flushMicrotasks();
          expect(
            async.pendingTimers.single.duration,
            const Duration(milliseconds: 400),
          );

          sub.close();
          container.dispose();
          expect(async.pendingTimers, isEmpty);
        });
      },
    );

    test(
      'with the default retry: an event after the error does not stop the retry',
      () {
        fakeAsync((async) {
          final source = Source();
          var runs = 0;
          final provider = StreamProvider.autoDispose<int>((ref) {
            runs++;
            return source.open();
          });
          final container = ProviderContainer();
          final sub = container.listen(provider, (_, _) {});
          async.flushMicrotasks();

          source.last.addError(Exception('a hiccup'));
          async.flushMicrotasks();
          source.last.add(1);
          async.flushMicrotasks();
          // The event arrives on the same subscription...
          expect(container.read(provider).value, 1);
          // ...but the timer is still pending, and reopens anyway.
          expect(async.pendingTimers, hasLength(1));
          async.elapse(const Duration(milliseconds: 200));
          async.flushMicrotasks();
          expect(runs, 2);
          expect(source.cancels, 1);

          sub.close();
          container.dispose();
        });
      },
    );

    test(
      'with the default retry: an Error (a programming error) is not retried',
      () {
        fakeAsync((async) {
          final source = Source();
          final provider = StreamProvider.autoDispose<int>(
            (ref) => source.open(),
          );
          final container = ProviderContainer();
          final sub = container.listen(provider, (_, _) {});
          async.flushMicrotasks();

          source.last.addError(StateError('a bug'));
          async.flushMicrotasks();
          expect(container.read(provider).isLoading, isFalse);
          expect(container.read(provider).hasError, isTrue);
          expect(async.pendingTimers, isEmpty);

          sub.close();
          container.dispose();
        });
      },
    );

    test(
      'with retry: (_, _) => null: no timer, the error is kept, a later event arrives',
      () {
        fakeAsync((async) {
          final source = Source();
          var runs = 0;
          final provider = StreamProvider.autoDispose<int>((ref) {
            runs++;
            return source.open();
          }, retry: (_, _) => null);
          final container = ProviderContainer();
          final states = <AsyncValue<int>>[];
          final sub = container.listen(provider, (_, next) => states.add(next));
          async.flushMicrotasks();

          source.last.add(1);
          source.last.addError(Exception('the connection dropped'));
          async.flushMicrotasks();

          final failed = container.read(provider);
          expect(failed.hasError, isTrue);
          expect(failed.isLoading, isFalse);
          expect(failed.retrying, isFalse);
          expect(async.pendingTimers, isEmpty);

          // The subscription is still open (Riverpod listens without cancelOnError).
          expect(source.last.hasListener, isTrue);
          source.last.add(2);
          async.flushMicrotasks();
          expect(container.read(provider), isA<AsyncData<int>>());
          expect(container.read(provider).value, 2);

          async.elapse(const Duration(minutes: 2));
          expect(runs, 1);
          expect(source.cancels, 0);
          expect(async.pendingTimers, isEmpty);
          expect(states.map((s) => s.runtimeType.toString()), [
            'AsyncData<int>',
            'AsyncError<int>',
            'AsyncData<int>',
          ]);

          sub.close();
          container.dispose();
        });
      },
    );

    test(
      'a StreamNotifierProvider with retry: (_, _) => null behaves the same',
      () {
        fakeAsync((async) {
          final source = Source();
          final signal = NotifierProvider<RefetchSignal, int>(
            RefetchSignal.new,
          );
          final provider = StreamNotifierProvider.autoDispose<Remembering, int>(
            () => Remembering(source, signal),
            retry: (_, _) => null,
          );
          final container = ProviderContainer();
          final sub = container.listen(provider, (_, _) {});
          async.flushMicrotasks();

          source.last.addError(Exception('the connection dropped'));
          async.flushMicrotasks();
          expect(container.read(provider).hasError, isTrue);
          expect(async.pendingTimers, isEmpty);

          source.last.add(3);
          async.flushMicrotasks();
          expect(container.read(provider).value, 3);
          async.elapse(const Duration(minutes: 2));
          expect(container.read(provider.notifier).builds, 1);

          sub.close();
          container.dispose();
        });
      },
    );
  });

  group('TickerMode', () {
    testWidgets('disabled pauses the source subscription, enabled resumes it', (
      tester,
    ) async {
      final source = Source();
      final provider = StreamProvider.autoDispose<int>(
        (ref) => source.open(),
        retry: (_, _) => null,
      );
      final enabled = ValueNotifier<bool>(true);
      addTearDown(enabled.dispose);
      final shown = <int?>[];

      await tester.pumpWidget(
        ProviderScope(
          child: ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (context, on, _) => TickerMode(
              enabled: on,
              child: Consumer(
                builder: (context, ref, _) {
                  shown.add(ref.watch(provider).value);
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      source.last.add(1);
      await tester.pump();
      expect(shown.last, 1);
      expect((source.pauses, source.resumes), (0, 0));

      enabled.value = false;
      await tester.pump();
      expect(source.pauses, 1);
      expect(source.last.isPaused, isTrue);
      expect(source.cancels, 0);

      // While paused, the source holds what it is given: nothing is delivered.
      source.last.add(2);
      await tester.pump();
      expect(shown.last, 1);

      enabled.value = true;
      await tester.pump();
      expect(source.resumes, 1);
      expect(source.last.isPaused, isFalse);
      await tester.pump();
      expect(shown.last, 2);
      // One subscription all along: a pause is not a cancel.
      expect(source.opened, hasLength(1));
      expect(source.cancels, 0);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(source.cancels, 1);
    });
  });

  group('a StreamNotifier', () {
    test(
      'keeps its fields across a rebuild caused by ref.watch, not across a disposal',
      () {
        fakeAsync((async) {
          final source = Source();
          final signal = NotifierProvider<RefetchSignal, int>(
            RefetchSignal.new,
          );
          final provider = StreamNotifierProvider.autoDispose<Remembering, int>(
            () => Remembering(source, signal),
            retry: (_, _) => null,
          );
          final container = ProviderContainer();
          var sub = container.listen(provider, (_, _) {});
          async.flushMicrotasks();

          final first = container.read(provider.notifier);
          source.last.add(41);
          async.flushMicrotasks();
          expect(first.lastSeen, 41);

          container.read(signal.notifier).fire();
          async.flushMicrotasks();
          container.read(provider);
          async.flushMicrotasks();

          // Rebuilt: a new stream, the old one cancelled, the same instance with its field.
          expect(source.opened, hasLength(2));
          expect(source.cancels, 1);
          final second = container.read(provider.notifier);
          expect(identical(first, second), isTrue);
          expect(second.builds, 2);
          expect(second.lastSeen, 41);

          // Disposed (auto-dispose, nobody listens): the next one starts from nothing.
          sub.close();
          // Riverpod disposes on a zero-length timer.
          async.elapse(Duration.zero);
          expect(source.cancels, 2);
          sub = container.listen(provider, (_, _) {});
          async.flushMicrotasks();
          final third = container.read(provider.notifier);
          expect(identical(first, third), isFalse);
          expect(third.lastSeen, isNull);
          expect(third.builds, 1);

          sub.close();
          container.dispose();
        });
      },
    );
  });
}
