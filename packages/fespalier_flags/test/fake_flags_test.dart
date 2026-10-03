import 'package:fespalier/fespalier.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:fespalier_flags/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const labs = BoolFlag('labs');

/// Runs [body] and returns what it reported to `FlutterError.reportError`.
List<FlutterErrorDetails> reported(void Function() body) {
  final reports = <FlutterErrorDetails>[];
  final original = FlutterError.onError;
  FlutterError.onError = reports.add;
  try {
    body();
  } finally {
    FlutterError.onError = original;
  }
  return reports;
}

void main() {
  group('values', () {
    test('answers its values with the conversions of ConstFlags', () {
      final fake = FakeFlags({
        'labs': true,
        'layout': 'list',
        'limit': 3,
        'rate': 2,
        'bad': 'x',
      });
      expect(fake.boolValue('labs', false), isTrue);
      expect(fake.stringValue('layout', 'grid'), 'list');
      expect(fake.intValue('limit', 1), 3);
      expect(fake.doubleValue('rate', 0.5), 2.0);
      expect(fake.boolValue('missing', true), isTrue);
      expect(fake.boolValue('bad', true), isTrue);
      expect(fake.intValue('bad', 7), 7);
      expect(fake.intValue('rate', 7), 2);
      expect(fake.values, {
        'labs': true,
        'layout': 'list',
        'limit': 3,
        'rate': 2,
        'bad': 'x',
      });
    });

    test('keeps its own copy of the map, and shows it read-only', () {
      final given = <String, Object>{'labs': true};
      final fake = FakeFlags(given);
      given['labs'] = false;
      expect(fake.boolValue('labs', false), isTrue);
      expect(() => fake.values['labs'] = false, throwsUnsupportedError);
    });
  });

  group('changes', () {
    test('set sends the key, synchronously, and a null removes it', () {
      final fake = FakeFlags({'labs': true});
      final events = <FlagsChanged>[];
      final sub = fake.changes.listen(events.add);
      addTearDown(sub.cancel);
      fake.set('labs', false);
      expect(events, hasLength(1), reason: 'delivered before set returned');
      expect(events.single.keys, {'labs'});
      expect(fake.boolValue('labs', true), isFalse);
      fake.set('labs', null);
      expect(events, hasLength(2));
      expect(fake.values, isEmpty);
      expect(
        fake.boolValue('labs', true),
        isTrue,
        reason: 'removed: the fallback',
      );
    });

    test('setAll sends one event naming every key, null removes', () {
      final fake = FakeFlags({'a': true, 'b': 1});
      final events = <FlagsChanged>[];
      final sub = fake.changes.listen(events.add);
      addTearDown(sub.cancel);
      fake.setAll({'a': null, 'b': 2, 'c': 'x'});
      expect(events, hasLength(1));
      expect(events.single.keys, {'a', 'b', 'c'});
      expect(fake.values, {'b': 2, 'c': 'x'});
    });

    test('listenerCount follows the listeners', () async {
      final fake = FakeFlags();
      expect(fake.listenerCount, 0);
      final first = fake.changes.listen((_) {});
      final second = fake.changes.listen((_) {});
      expect(fake.listenerCount, 2);
      await first.cancel();
      expect(fake.listenerCount, 1);
      await second.cancel();
      expect(fake.listenerCount, 0);
    });

    test(
      'a flag behind it follows set, and the container lets it go',
      () async {
        final fake = FakeFlags();
        final container = ProviderContainer(
          overrides: [flagSource.overrideWithValue(fake)],
        );
        final seen = <bool>[];
        container.listen(
          flag(labs),
          (_, next) => seen.add(next),
          fireImmediately: true,
        );
        expect(fake.listenerCount, 1);
        fake.set('labs', true);
        expect(seen, [false, true]);
        container.dispose();
        expect(fake.listenerCount, 0);
      },
    );
  });

  group('strict', () {
    test('a key it lacks throws F3, and says so to Flutter', () {
      final fake = FakeFlags.strict({'labs': true});
      expect(fake.boolValue('labs', false), isTrue);
      final reports = reported(() {
        expect(
          () => fake.boolValue('labz', false),
          throwsA(
            isA<StateError>().having(
              (e) => e.toString(),
              'toString',
              'Bad state: FakeFlags has no value for "labz"',
            ),
          ),
        );
      });
      expect(reports, hasLength(1));
      expect(reports.single.library, 'fespalier_flags');
      expect(
        reports.single.exception.toString(),
        'Bad state: FakeFlags has no value for "labz"',
      );
    });

    test('a value of another type throws F4, for each type', () {
      final fake = FakeFlags.strict({
        'labs': 'yes',
        'layout': 1,
        'limit': 1.5,
        'rate': 'fast',
      });
      String message(void Function() read) {
        late String text;
        reported(() {
          try {
            read();
          } on StateError catch (e) {
            text = e.toString();
          }
        });
        return text;
      }

      expect(
        message(() => fake.boolValue('labs', false)),
        'Bad state: FakeFlags has "labs" = yes (String), which is not a bool',
      );
      expect(
        message(() => fake.stringValue('layout', 'grid')),
        'Bad state: FakeFlags has "layout" = 1 (int), which is not a String',
      );
      expect(
        message(() => fake.intValue('limit', 1)),
        'Bad state: FakeFlags has "limit" = 1.5 (double), which is not a int',
      );
      expect(
        message(() => fake.doubleValue('rate', 1)),
        'Bad state: FakeFlags has "rate" = fast (String), which is not a double',
      );
    });

    test('an int is a double, as everywhere', () {
      final fake = FakeFlags.strict({'rate': 2});
      expect(fake.doubleValue('rate', 0.5), 2.0);
    });

    testWidgets(
      'behind a flag, a typo fails the widget test, and the flag reads its fallback',
      (tester) async {
        final fake = FakeFlags.strict({'labs': true});
        final container = ProviderContainer(
          overrides: [flagSource.overrideWithValue(fake)],
        );
        addTearDown(container.dispose);
        final lines = <String>[];
        final original = debugPrint;
        debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
        try {
          expect(container.read(flag(const BoolFlag('labz'))), isFalse);
        } finally {
          debugPrint = original;
        }
        // A raw container disposes what nothing listens to on a zero-duration timer.
        await tester.pump(const Duration(milliseconds: 1));
        expect(lines, [
          'fespalier_flags: reading labz threw, so its fallback (false) is used: '
              'Bad state: FakeFlags has no value for "labz"',
        ]);
        // The binding recorded Flutter's report: that is what fails this test, so take it.
        final exception = tester.takeException();
        expect(
          exception.toString(),
          'Bad state: FakeFlags has no value for "labz"',
        );
      },
    );
  });
}
