// ChangeCodec (since 0.18.0): a raw message decodes to events in the feed's open, a bad or unknown
// message is skipped and counted, and nothing about the skip ever numbers an event or ends the
// stream.
import 'package:fake_async/fake_async.dart';
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

/// One event of a line: `order:42`, `cart`, or a variant this app does not know.
CoreEvent decodeLine(String raw) {
  final parts = raw.split(':');
  return switch (parts.first) {
    'order' => OrderChanged(int.parse(parts[1])),
    'cart' => const CartCleared(),
    'archived' => throw const UnknownChange(),
    _ => throw FormatException('not an event', raw),
  };
}

/// The items of a message: comma-separated, `!` a batch that cannot be read, `?` a batch whose
/// variant is unknown, and an empty message a batch of none.
Iterable<String> splitLines(String raw) => switch (raw) {
  '!' => throw const FormatException('torn batch'),
  '?' => throw const UnknownChange(),
  '' => const <String>[],
  _ => raw.split(','),
};

ChangeCodec<String, CoreEvent> lines({
  void Function(Object, StackTrace)? onSkipped,
}) => ChangeCodec.batch<String, String, CoreEvent>(
  splitLines,
  decodeLine,
  onSkipped: onSkipped,
);

Matcher order(int id) => isA<OrderChanged>().having((e) => e.id, 'id', id);

void main() {
  group('decode', () {
    test('one message is one event', () {
      final skipped = <Object>[];
      final codec = lines(onSkipped: (r, _) => skipped.add(r));
      expect(codec.decode('order:42'), [order(42)]);
      expect(codec.unknownCount, 0);
      expect(codec.errorCount, 0);
    });

    test('an unknown variant is skipped and counted, not thrown', () {
      final skipped = <Object>[];
      final codec = lines(onSkipped: (r, _) => skipped.add(r));
      expect(codec.decode('archived:1'), isEmpty);
      expect(codec.unknownCount, 1);
      expect(codec.errorCount, 0);
      expect(skipped.single, isA<UnknownChange>());
    });

    test(
      'a message that does not decode is skipped and counted, not thrown',
      () {
        final skipped = <Object>[];
        final codec = lines(onSkipped: (r, _) => skipped.add(r));
        expect(codec.decode('order:x'), isEmpty);
        expect(codec.decode('order'), isEmpty);
        expect(codec.decode('???'), isEmpty);
        expect(codec.errorCount, 3);
        expect(skipped, [
          isA<FormatException>(),
          isA<RangeError>(),
          isA<FormatException>(),
        ]);
      },
    );

    test('a batch is its items, in order', () {
      final codec = lines();
      expect(codec.decode('order:7,order:42,cart'), [
        order(7),
        order(42),
        isA<CartCleared>(),
      ]);
    });

    test(
      'an item that fails is skipped, the rest of its batch goes through',
      () {
        final codec = lines();
        expect(codec.decode('order:1,archived:2,order:x,cart'), [
          order(1),
          isA<CartCleared>(),
        ]);
        expect(codec.unknownCount, 1);
        expect(codec.errorCount, 1);
      },
    );

    test('a batch whose items cannot be read is skipped whole', () {
      final codec = lines();
      expect(codec.decode('!'), isEmpty);
      expect(codec.errorCount, 1);
      expect(codec.decode('?'), isEmpty);
      expect(codec.unknownCount, 1);
    });

    test('a batch of none is no event and no skip', () {
      final codec = lines();
      expect(codec.decode(''), isEmpty);
      expect(codec.unknownCount, 0);
      expect(codec.errorCount, 0);
    });
  });

  for (final broadcast in [true, false]) {
    group(
      broadcast ? 'over a broadcast feed' : 'over a single-subscription feed',
      () {
        late FakeChangeSource<String> source;
        late List<Object> skipped;
        late ChangeCodec<String, CoreEvent> codec;
        late ChangeFeed<CoreEvent> feed;
        late ChangeTopic<CoreEvent, int> orderChanged;
        late ProviderContainer container;

        setUp(() {
          source = FakeChangeSource<String>(broadcast: broadcast);
          skipped = [];
          codec = ChangeCodec<String, CoreEvent>(
            decodeLine,
            onSkipped: (r, _) => skipped.add(r),
          );
          feed = ChangeFeed<CoreEvent>(
            (ref) => source.stream.transform(codec),
            name: 'core',
          );
          orderChanged = feed.topic<int>(
            (e, id) => e is OrderChanged && e.id == id,
          );
          container = ProviderContainer();
          addTearDown(container.dispose);
        });

        test('a bad message keeps the feed alive', () async {
          final values = <int>[];
          container.listen(orderChanged(42), (_, next) => values.add(next));
          await container.pump();

          source.emit('order:42');
          await container.pump();
          source.emit('order:x');
          await container.pump();
          source.emit('archived:3');
          await container.pump();
          source.emit('order:42');
          await container.pump();

          expect(values, [1, 2]);
          final latest = container.read(feed.latest);
          expect(latest.hasError, isFalse);
          expect(latest.value!.seq, 2);
          expect(latest.value!.event, order(42));
          expect(source.hasListener, isTrue);
          expect(source.listenCount, 1);
          expect(codec.errorCount, 1);
          expect(codec.unknownCount, 1);
          expect(skipped, hasLength(2));
        });

        test('a topic moves only on a matching decoded event', () async {
          final values = <int>[];
          container.listen(orderChanged(42), (_, next) => values.add(next));
          await container.pump();

          source.emit('order:7');
          await container.pump();
          source.emit('cart');
          await container.pump();
          source.emit('archived:42');
          await container.pump();
          expect(values, isEmpty);

          source.emit('order:42');
          await container.pump();
          expect(values, [1]);

          source.emit('order:42');
          await container.pump();
          expect(values, [1, 2]);
        });

        group('batches', () {
          late ChangeFeed<CoreEvent> batches;
          late ChangeTopic<CoreEvent, int> batchOrderChanged;
          late List<int> seen42;
          late List<int> seen7;
          late List<int> any;

          setUp(() async {
            batches = ChangeFeed<CoreEvent>(
              (ref) => source.stream.transform(lines()),
              name: 'batches',
            );
            batchOrderChanged = batches.topic<int>(
              (e, id) => e is OrderChanged && e.id == id,
            );
            seen42 = [];
            seen7 = [];
            any = [];
            container.listen(batches.latest, (_, _) {});
            container.listen(
              batchOrderChanged(42),
              (_, next) => seen42.add(next),
            );
            container.listen(
              batchOrderChanged(7),
              (_, next) => seen7.add(next),
            );
            container.listen(batches.any, (_, next) => any.add(next));
            await container.pump();
          });

          test(
            'a batch numbers each event, and a topic moves once for it',
            () async {
              source.emit('order:7,order:42,cart');
              await settle(container);

              expect(seen42, [1]);
              expect(seen7, [1]);
              expect(any.last, 3);
              final latest = container.read(batches.latest);
              expect(latest.value!.seq, 3);
              expect(latest.value!.event, isA<CartCleared>());
            },
          );

          test(
            'an item that fails does not hide the rest of its batch',
            () async {
              source.emit('order:42,archived:1,order:x,order:7');
              await settle(container);

              expect(seen42, [1]);
              expect(seen7, [1]);
              expect(any.last, 2);
              expect(container.read(batches.latest).value!.seq, 2);
            },
          );

          test('a batch longer than the log does not lose a match', () async {
            source.emit(
              [
                'order:42',
                for (var i = 0; i < changeLogCapacity + 10; i++) 'order:7',
              ].join(','),
            );
            await settle(container);

            expect(seen42, isNotEmpty);
            expect(any.last, changeLogCapacity + 11);
          });
        });

        test('an error of the source is still an error of latest', () async {
          final values = <int>[];
          container.listen(orderChanged(42), (_, next) => values.add(next));
          await container.pump();

          source.emitError(StateError('core stopped'));
          await container.pump();
          expect(container.read(feed.latest).hasError, isTrue);
          expect(codec.errorCount, 0);

          source.emit('order:42');
          await container.pump();
          expect(values, [1]);
        });

        test(
          'what onSkipped throws is an error of latest, and the feed goes on',
          () async {
            final throwing = ChangeCodec<String, CoreEvent>(
              decodeLine,
              onSkipped: (_, _) => throw StateError('logger down'),
            );
            final loud = ChangeFeed<CoreEvent>(
              (ref) => source.stream.transform(throwing),
              name: 'loud',
            );
            final loudOrder = loud.topic<int>(
              (e, id) => e is OrderChanged && e.id == id,
            );
            final values = <int>[];
            container.listen(loudOrder(42), (_, next) => values.add(next));
            await container.pump();

            source.emit('???');
            await container.pump();
            expect(container.read(loud.latest).hasError, isTrue);

            source.emit('order:42');
            await container.pump();
            expect(values, [1]);
            expect(throwing.errorCount, 1);
          },
        );

        test('disposing the container cancels the raw source', () async {
          container.listen(orderChanged(1), (_, _) {});
          await container.pump();
          expect(source.hasListener, isTrue);
          container.dispose();
          expect(source.hasListener, isFalse);
          expect(source.cancelCount, 1);
        });
      },
    );
  }

  test('a reopened stream is decoded again, numbered from 1', () async {
    final sources = <FakeChangeSource<String>>[];
    final core = Provider<int>((ref) {
      sources.add(FakeChangeSource<String>(broadcast: false));
      return sources.length;
    });
    final codec = ChangeCodec<String, CoreEvent>(decodeLine);
    final feed = ChangeFeed<CoreEvent>(
      (ref) => sources[ref.watch(core) - 1].stream.transform(codec),
    );
    final topic = feed.topic<int>((e, id) => e is OrderChanged && e.id == id);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final values = <int>[];
    container.listen(topic(1), (_, next) => values.add(next));
    await container.pump();
    sources[0].emit('order:1');
    await container.pump();
    expect(values, [1]);

    container.invalidate(core);
    await container.pump();
    expect(sources[0].hasListener, isFalse);
    sources[1].emit('order:x');
    sources[1].emit('order:1');
    await container.pump();
    expect(values, [1, 2]);
    expect(container.read(feed.latest).value!.seq, 1);
    expect(codec.errorCount, 1);
  });

  test('decode feeds an InvalidationTable without a feed', () {
    final order = FutureProvider.family<String, int>((ref, id) async => '$id');
    final cart = FutureProvider<String>((ref) async => 'cart');
    final table = InvalidationTable<CoreEvent>([
      InvalidationRule.on<OrderChanged, CoreEvent>((e) => [order(e.id)]),
      InvalidationRule.on<CartCleared, CoreEvent>((_) => [cart]),
    ]);
    final invalidated = <ProviderOrFamily>[];
    for (final e in lines().decode('order:42,archived:1,cart')) {
      table.apply(e, invalidated.add);
    }
    expect(invalidated, [order(42), cart]);
  });

  test('a skipped message starts no timer and leaves latest loading', () {
    fakeAsync((async) {
      final source = FakeChangeSource<String>();
      final feed = ChangeFeed<CoreEvent>(
        (ref) =>
            source.stream.transform(ChangeCodec<String, CoreEvent>(decodeLine)),
      );
      final container = ProviderContainer();
      final held = container.listen(feed.latest, (_, _) {});
      async.flushMicrotasks();

      source.emit('order:x');
      source.emit('archived:1');
      async.flushMicrotasks();

      expect(async.pendingTimers, isEmpty);
      final state = container.read(feed.latest);
      expect(state.hasError, isFalse);
      expect(state.isLoading, isTrue);

      held.close();
      container.dispose();
    });
  });
}
