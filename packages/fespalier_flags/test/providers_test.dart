// The flag providers on a plain ProviderContainer: what is read, when it is read again, and what is
// listened to. A container disposes what nothing listens to on a zero-duration timer, so a test that
// checks a cancellation waits one turn of the event loop (`settled`).
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const labs = BoolFlag('labs');
const layout = StringFlag('layout', fallback: 'grid');
const limit = IntFlag('limit', fallback: 10);
const rate = DoubleFlag('rate', fallback: 0.5);

Future<void> settled() => Future<void>.delayed(Duration.zero);

ProviderContainer containerOf(FlagSource? source) {
  final container = ProviderContainer(
    overrides: [if (source != null) flagSource.overrideWithValue(source)],
  );
  addTearDown(container.dispose);
  return container;
}

/// Watches [f] the way a widget or a guard would, and records each value it sees.
({List<T> seen, ProviderSubscription<T> sub}) watch<T extends Object>(
  ProviderContainer c,
  FeatureFlag<T> f,
) {
  final seen = <T>[];
  final sub = c.listen<T>(
    flag(f),
    (_, next) => seen.add(next),
    fireImmediately: true,
  );
  addTearDown(sub.close);
  return (seen: seen, sub: sub);
}

void main() {
  group('values', () {
    test('with no override every flag is its fallback', () {
      final container = containerOf(null);
      expect(container.read(flag(labs)), isFalse);
      expect(
        container.read(flag(const BoolFlag('on', fallback: true))),
        isTrue,
      );
      expect(container.read(flag(layout)), 'grid');
      expect(container.read(flag(limit)), 10);
      expect(container.read(flag(rate)), 0.5);
      expect(container.read(flagSource), isA<ConstFlags>());
    });

    test(
      'ConstFlags answers its values, widens an int and refuses a value of another type',
      () {
        final container = containerOf(
          const ConstFlags({
            'labs': true,
            'layout': 'list',
            'limit': 3,
            'rate': 2, // an int at the source, read as a double
            'wrong.bool': 'yes',
            'wrong.int': 1.5, // a double is not an int
            'wrong.string': 7,
            'wrong.double': 'fast',
          }),
        );
        expect(container.read(flag(labs)), isTrue);
        expect(container.read(flag(layout)), 'list');
        expect(container.read(flag(limit)), 3);
        expect(container.read(flag(rate)), 2.0);
        expect(container.read(flag(const BoolFlag('wrong.bool'))), isFalse);
        expect(
          container.read(flag(const IntFlag('wrong.int', fallback: 4))),
          4,
        );
        expect(
          container.read(flag(const StringFlag('wrong.string', fallback: 's'))),
          's',
        );
        expect(
          container.read(
            flag(const DoubleFlag('wrong.double', fallback: 0.25)),
          ),
          0.25,
        );
      },
    );

    test('a flag is there at once: a value, never an AsyncValue', () {
      final container = containerOf(CountingFlags({'labs': true}));
      final value = container.read(flag(labs));
      expect(value, isA<bool>());
      expect(value, isTrue);
    });
  });

  group('changes', () {
    test('a change notifies once, and an equal value does not', () {
      final source = CountingFlags({'labs': false});
      final container = containerOf(source);
      final watched = watch(container, labs);
      expect(watched.seen, [false]);
      source.set('labs', true);
      expect(watched.seen, [false, true]);
      source.set('labs', true);
      source.send(const FlagsChanged({'labs'}));
      expect(watched.seen, [
        false,
        true,
      ], reason: 'the same value is not a change');
      source.set('labs', false);
      expect(watched.seen, [false, true, false]);
    });

    test("a keyed event for another key reads nothing", () {
      final source = CountingFlags({'labs': true, 'other': 1});
      final container = containerOf(source);
      watch(container, labs);
      expect(source.reads, {'labs': 1});
      source.set('other', 2);
      source.send(const FlagsChanged({'unrelated'}));
      expect(source.reads, {'labs': 1}, reason: 'no key it names is watched');
      source.set('labs', false);
      expect(source.reads, {'labs': 2});
    });

    test(
      'FlagsChanged.all() reads every watched flag again, and only those',
      () {
        final source = CountingFlags({
          'labs': true,
          'layout': 'grid',
          'limit': 1,
          'rate': 1.0,
        });
        final container = containerOf(source);
        final a = watch(container, labs);
        final b = watch(container, layout);
        final c = watch(container, limit);
        expect(source.totalReads, 3, reason: 'rate is not watched');
        source.values
          ..['labs'] = false
          ..['layout'] = 'list'
          ..['rate'] = 9.0;
        source.send(const FlagsChanged.all());
        expect(source.reads, {'labs': 2, 'layout': 2, 'limit': 2});
        expect(a.seen, [true, false]);
        expect(b.seen, ['grid', 'list']);
        expect(c.seen, [1], reason: 'limit has the same value');
      },
    );

    test('a dependent runs again only when the value differs', () async {
      final source = CountingFlags({'labs': false});
      final container = containerOf(source);
      var runs = 0;
      final derived = Provider.autoDispose<String>((ref) {
        runs++;
        return ref.watch(flag(labs)) ? 'on' : 'off';
      });
      final sub = container.listen(derived, (_, _) {});
      addTearDown(sub.close);
      expect(runs, 1);
      source.send(const FlagsChanged.all());
      await container.pump();
      expect(runs, 1);
      source.set('labs', true);
      await container.pump();
      expect(runs, 2);
      expect(sub.read(), 'on');
    });

    test(
      'an event replayed while listening is not a change and breaks nothing',
      () async {
        final source = CountingFlags({'labs': true})
          ..replay = const FlagsChanged.all();
        final container = containerOf(source);
        final watched = watch(container, labs);
        expect(watched.seen, [true]);
        expect(source.reads, {
          'labs': 1,
        }, reason: 'build read the current value; the replay read nothing');
        source.set('labs', false);
        expect(watched.seen, [true, false]);
      },
    );
  });

  group('the subscription to changes', () {
    test(
      'one per container, opened by the first watched flag and closed with the last',
      () async {
        final source = CountingFlags({'labs': true});
        final container = containerOf(source);
        expect(source.listening, 0);
        final a = watch(container, labs);
        final b = watch(container, layout);
        final c = watch(container, limit);
        expect(source.listening, 1);
        expect(source.changesGets, 1);
        a.sub.close();
        b.sub.close();
        await settled();
        expect(source.listening, 1, reason: 'one flag is still watched');
        c.sub.close();
        await settled();
        expect(source.listening, 0);
      },
    );

    test('a source with no changes is not subscribed to', () async {
      final source = CountingFlags({'labs': true})..staticValues = true;
      final container = containerOf(source);
      final watched = watch(container, labs);
      expect(watched.seen, [true]);
      expect(source.listening, 0);
      watched.sub.close();
      await settled();
      expect(source.listening, 0);
    });

    test('the container closes it', () async {
      final source = CountingFlags({'labs': true});
      final container = ProviderContainer(
        overrides: [flagSource.overrideWithValue(source)],
      );
      container.listen(flag(labs), (_, _) {});
      expect(source.listening, 1);
      container.dispose();
      expect(source.listening, 0);
    });

    test(
      'another source in updateOverrides is listened to, and every flag is read again',
      () async {
        final first = CountingFlags({'labs': false});
        final second = CountingFlags({'labs': true});
        final container = containerOf(first);
        final watched = watch(container, labs);
        expect(watched.seen, [false]);
        container.updateOverrides([flagSource.overrideWithValue(second)]);
        await container.pump();
        expect(watched.seen, [false, true]);
        expect(first.listening, 0);
        expect(second.listening, 1);
        second.set('labs', false);
        expect(watched.seen, [false, true, false]);
        first.set('labs', true);
        expect(watched.seen, [
          false,
          true,
          false,
        ], reason: 'the first source is no longer listened to');
      },
    );
  });

  group('a source that misbehaves', () {
    test('a read that throws is the fallback, with F1 in debug', () async {
      final source = CountingFlags({'labs': true})
        ..throwing['labs'] = StateError('not started');
      final container = containerOf(source);
      final lines = await printed(
        () => expect(container.read(flag(labs)), isFalse),
      );
      expect(lines, [
        'fespalier_flags: reading labs threw, so its fallback (false) is used: Bad state: not started',
      ]);
      source.throwing.clear();
      final other = containerOf(source);
      expect(
        other.read(flag(labs)),
        isTrue,
        reason: 'a later read asks the source again',
      );
    });

    test('F1 names the fallback of each type', () async {
      final source = CountingFlags()
        ..throwing['layout'] = 'boom'
        ..throwing['limit'] = 'boom'
        ..throwing['rate'] = 'boom';
      final container = containerOf(source);
      final lines = await printed(() {
        expect(container.read(flag(layout)), 'grid');
        expect(container.read(flag(limit)), 10);
        expect(container.read(flag(rate)), 0.5);
      });
      expect(lines, [
        'fespalier_flags: reading layout threw, so its fallback (grid) is used: boom',
        'fespalier_flags: reading limit threw, so its fallback (10) is used: boom',
        'fespalier_flags: reading rate threw, so its fallback (0.5) is used: boom',
      ]);
    });

    test(
      'a changes getter that throws is F2, and the flag still reads',
      () async {
        final source = CountingFlags({'labs': true})
          ..changesThrows = StateError('no stream');
        final container = containerOf(source);
        final lines = await printed(
          () => expect(container.read(flag(labs)), isTrue),
        );
        expect(lines, [
          "fespalier_flags: the flag source's changes reported an error: Bad state: no stream",
        ]);
      },
    );

    test('a stream error is F2, and the subscription stays', () async {
      final source = CountingFlags({'labs': false});
      final container = containerOf(source);
      final watched = watch(container, labs);
      final lines = await printed(() => source.sendError('lost connection'));
      expect(lines, [
        "fespalier_flags: the flag source's changes reported an error: lost connection",
      ]);
      expect(source.listening, 1);
      source.set('labs', true);
      expect(watched.seen, [false, true]);
    });
  });
}
