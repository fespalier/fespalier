// The hybrid logical clock: monotonic, causal, totally ordered.
import 'package:clock/clock.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter_test/flutter_test.dart';

Hlc at(int millis, {int counter = 0, String node = 'a'}) =>
    Hlc(millis, counter, node);

void main() {
  test('next follows the wall clock', () {
    withClock(Clock.fixed(DateTime.fromMillisecondsSinceEpoch(5000)), () {
      expect(Hlc.next(null, 'a'), at(5000));
      expect(Hlc.next(at(1000), 'a'), at(5000));
    });
  });

  test('next is monotonic when the wall clock stands still or steps back', () {
    withClock(Clock.fixed(DateTime.fromMillisecondsSinceEpoch(5000)), () {
      final first = Hlc.next(null, 'a');
      final second = Hlc.next(first, 'a');
      expect(second.compareTo(first), greaterThan(0));
      expect(second, at(5000, counter: 1));
      // The clock steps back by an hour: the stamp does not.
      final back = withClock(
        Clock.fixed(DateTime.fromMillisecondsSinceEpoch(5000 - 3600000)),
        () => Hlc.next(second, 'a'),
      );
      expect(back, at(5000, counter: 2));
    });
  });

  test('receive moves past a stamp from a device whose clock is ahead', () {
    withClock(Clock.fixed(DateTime.fromMillisecondsSinceEpoch(5000)), () {
      final remote = at(9000, counter: 3, node: 'b');
      final mine = Hlc.receive(at(4000), remote, 'a');
      expect(mine.compareTo(remote), greaterThan(0));
      expect(mine, at(9000, counter: 4));
      // And what this device writes next is later than the remote's stamp too.
      expect(Hlc.next(mine, 'a').compareTo(remote), greaterThan(0));
    });
  });

  test('receive with every clock equal advances the counter past both', () {
    withClock(Clock.fixed(DateTime.fromMillisecondsSinceEpoch(5000)), () {
      expect(
        Hlc.receive(at(5000, counter: 2), at(5000, counter: 7, node: 'b'), 'a'),
        at(5000, counter: 8),
      );
      expect(Hlc.receive(null, at(100, node: 'b'), 'a'), at(5000));
    });
  });

  test('pack and parse round-trip, and packed text sorts like the stamps', () {
    final stamps = [
      at(5, node: 'a'),
      at(5, counter: 1, node: 'a'),
      at(5, counter: 1, node: 'b'),
      at(5, counter: 16, node: 'a'),
      at(1700000000000, node: 'c0ffee'),
    ];
    for (final stamp in stamps) {
      expect(Hlc.parse(stamp.pack()), stamp);
    }
    final byStamp = [...stamps]..sort();
    final byText = [...stamps]..sort((a, b) => a.pack().compareTo(b.pack()));
    expect(byText, byStamp);
  });

  test('parse refuses text that is no stamp', () {
    expect(() => Hlc.parse('nope'), throwsFormatException);
    expect(() => Hlc.parse('1-2'), throwsFormatException);
  });

  test('the order is total: millis, then counter, then node', () {
    expect(at(1).compareTo(at(2)), lessThan(0));
    expect(at(1, counter: 2).compareTo(at(1, counter: 1)), greaterThan(0));
    expect(at(1, node: 'a').compareTo(at(1, node: 'b')), lessThan(0));
    expect(at(1).compareTo(at(1)), 0);
    expect(at(2) > at(1), isTrue);
  });
}
