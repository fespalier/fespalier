import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:fespalier_flags/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const labs = BoolFlag('labs');

Future<void> turn() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'reads come from meanwhile until the source completes, then from the source',
    () async {
      final completer = Completer<FlagSource>();
      final flags = AsyncFlags(
        completer.future,
        meanwhile: const ConstFlags({'labs': true, 'layout': 'list'}),
      );
      expect(flags.isReady, isFalse);
      expect(flags.boolValue('labs', false), isTrue);
      expect(flags.stringValue('layout', 'grid'), 'list');
      expect(flags.intValue('limit', 3), 3);
      expect(flags.doubleValue('rate', 0.5), 0.5);
      completer.complete(
        const ConstFlags({'labs': false, 'limit': 9, 'rate': 2}),
      );
      await turn();
      expect(flags.isReady, isTrue);
      expect(flags.boolValue('labs', true), isFalse);
      expect(
        flags.stringValue('layout', 'grid'),
        'grid',
        reason: 'the new source has no layout: the fallback',
      );
      expect(flags.intValue('limit', 3), 9);
      expect(flags.doubleValue('rate', 0.5), 2.0);
    },
  );

  test('with no meanwhile, every flag is its fallback until then', () async {
    final completer = Completer<FlagSource>();
    final flags = AsyncFlags(completer.future);
    expect(flags.boolValue('labs', false), isFalse);
    expect(flags.boolValue('labs', true), isTrue);
    completer.complete(const ConstFlags({'labs': true}));
    await turn();
    expect(flags.boolValue('labs', false), isTrue);
  });

  test(
    'a listener gets one FlagsChanged.all() at the switch, then the inner source events',
    () async {
      final completer = Completer<FlagSource>();
      final flags = AsyncFlags(completer.future);
      final events = <FlagsChanged>[];
      final sub = flags.changes.listen(events.add);
      addTearDown(sub.cancel);
      expect(events, isEmpty);
      final inner = FakeFlags({'labs': false});
      completer.complete(inner);
      await turn();
      expect(events, hasLength(1));
      expect(events.single.keys, isNull, reason: 'all');
      inner.set('labs', true);
      expect(events, hasLength(2));
      expect(events.last.keys, {'labs'});
      expect(flags.boolValue('labs', false), isTrue);
    },
  );

  test(
    'the meanwhile source events are forwarded until the switch, and then it is let go of',
    () async {
      final completer = Completer<FlagSource>();
      final meanwhile = FakeFlags({'labs': true});
      final flags = AsyncFlags(completer.future, meanwhile: meanwhile);
      final events = <FlagsChanged>[];
      final sub = flags.changes.listen(events.add);
      addTearDown(sub.cancel);
      expect(meanwhile.listenerCount, 1);
      meanwhile.set('labs', false);
      expect(events.map((e) => e.keys), [
        {'labs'},
      ]);
      final inner = FakeFlags();
      completer.complete(inner);
      await turn();
      expect(meanwhile.listenerCount, 0);
      expect(inner.listenerCount, 1);
      meanwhile.set('labs', true);
      expect(
        events,
        hasLength(2),
        reason:
            'only the switch since: the meanwhile source is no longer listened to',
      );
    },
  );

  test(
    'nothing is listened to while nobody listens, and the inner source is let go of with the last listener',
    () async {
      final completer = Completer<FlagSource>();
      final meanwhile = FakeFlags();
      final flags = AsyncFlags(completer.future, meanwhile: meanwhile);
      expect(meanwhile.listenerCount, 0);
      final inner = FakeFlags();
      completer.complete(inner);
      await turn();
      expect(
        inner.listenerCount,
        0,
        reason: 'completing subscribes to nothing by itself',
      );
      final sub = flags.changes.listen((_) {});
      expect(inner.listenerCount, 1);
      await sub.cancel();
      expect(inner.listenerCount, 0);
      final again = flags.changes.listen((_) {});
      expect(inner.listenerCount, 1);
      await again.cancel();
      expect(inner.listenerCount, 0);
    },
  );

  test('a source with no changes is simply not listened to', () async {
    final flags = AsyncFlags(Future.value(const ConstFlags({'labs': true})));
    final events = <FlagsChanged>[];
    final sub = flags.changes.listen(events.add);
    addTearDown(sub.cancel);
    await turn();
    expect(events, hasLength(1));
    expect(flags.boolValue('labs', false), isTrue);
  });

  test('a failing future keeps meanwhile and prints F5', () async {
    final completer = Completer<FlagSource>();
    final flags = AsyncFlags(
      completer.future,
      meanwhile: const ConstFlags({'labs': true}),
    );
    final events = <FlagsChanged>[];
    final sub = flags.changes.listen(events.add);
    addTearDown(sub.cancel);
    final lines = await printed(() async {
      completer.completeError(StateError('no network'));
      await turn();
    });
    expect(lines, [
      "fespalier_flags: AsyncFlags' source failed, so the values meanwhile stay: Bad state: no network",
    ]);
    expect(flags.isReady, isFalse);
    expect(flags.boolValue('labs', false), isTrue);
    expect(events, isEmpty, reason: 'no switch happened');
  });

  test(
    'a source whose changes getter throws reaches the listener as an error',
    () async {
      final completer = Completer<FlagSource>();
      final broken = CountingFlags()..changesThrows = StateError('no stream');
      final flags = AsyncFlags(completer.future);
      final errors = <Object>[];
      final events = <FlagsChanged>[];
      final sub = flags.changes.listen(events.add, onError: errors.add);
      addTearDown(sub.cancel);
      completer.complete(broken);
      await turn();
      expect(errors.single, isA<StateError>());
      expect(events, hasLength(1), reason: 'the switch is still announced');
    },
  );

  group('behind flagSource', () {
    test(
      'a watched flag is read again at the switch, and follows the new source',
      () async {
        final completer = Completer<FlagSource>();
        final container = ProviderContainer(
          overrides: [
            flagSource.overrideWithValue(
              AsyncFlags(
                completer.future,
                meanwhile: const ConstFlags({'labs': false}),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        final seen = <bool>[];
        final sub = container.listen(
          flag(labs),
          (_, next) => seen.add(next),
          fireImmediately: true,
        );
        addTearDown(sub.close);
        expect(seen, [false]);
        final inner = FakeFlags({'labs': true});
        completer.complete(inner);
        await turn();
        expect(seen, [false, true]);
        inner.set('labs', false);
        expect(seen, [false, true, false]);
      },
    );

    test(
      'a flag watched only after the switch reads the new source at once',
      () async {
        final flags = AsyncFlags(
          Future.value(const ConstFlags({'labs': true})),
        );
        await turn();
        final container = ProviderContainer(
          overrides: [flagSource.overrideWithValue(flags)],
        );
        addTearDown(container.dispose);
        expect(container.read(flag(labs)), isTrue);
      },
    );
  });
}
