import 'package:fespalier/fespalier.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _a = BoolFlag('a');

void main() {
  group('equality', () {
    test('the same type, key and fallback are equal, and hash alike', () {
      const first = BoolFlag('a');
      final second = BoolFlag('a', fallback: false);
      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(
        const StringFlag('s', fallback: 'x'),
        StringFlag('s', fallback: 'x'),
      );
      expect(
        const IntFlag('i', fallback: 1).hashCode,
        IntFlag('i', fallback: 1).hashCode,
      );
      expect(
        const DoubleFlag('d', fallback: 1.5),
        DoubleFlag('d', fallback: 1.5),
      );
    });

    test('another key, fallback or type is another flag', () {
      expect(const BoolFlag('a'), isNot(const BoolFlag('b')));
      expect(const BoolFlag('a'), isNot(const BoolFlag('a', fallback: true)));
      // The same key and the same number under two types.
      expect(
        const IntFlag('n', fallback: 1),
        isNot(const DoubleFlag('n', fallback: 1)),
      );
      expect(
        const StringFlag('n', fallback: '1'),
        isNot(const IntFlag('n', fallback: 1)),
      );
    });

    test('const and non-const declarations share one provider', () {
      final source = CountingFlags({'a': true});
      final scoped = ProviderContainer(
        overrides: [flagSource.overrideWithValue(source)],
      );
      addTearDown(scoped.dispose);
      final runtimeFlag = BoolFlag(['a'].join()); // not a constant
      expect(flag(_a), flag(runtimeFlag));
      final first = scoped.listen(flag(_a), (_, _) {});
      final second = scoped.listen(flag(runtimeFlag), (_, _) {});
      addTearDown(first.close);
      addTearDown(second.close);
      expect(first.read(), isTrue);
      expect(second.read(), isTrue);
      expect(source.reads['a'], 1, reason: 'read once: one provider');
    });
  });

  test('toString names the type, the key and the fallback', () {
    expect(
      const BoolFlag('labs').toString(),
      'BoolFlag(labs, fallback: false)',
    );
    expect(
      const StringFlag('layout', fallback: 'grid').toString(),
      'StringFlag(layout, fallback: grid)',
    );
    expect(
      const IntFlag('limit', fallback: 3).toString(),
      'IntFlag(limit, fallback: 3)',
    );
    expect(
      const DoubleFlag('rate', fallback: 0.5).toString(),
      'DoubleFlag(rate, fallback: 0.5)',
    );
  });

  test('FlagsChanged says which keys it affects', () {
    expect(const FlagsChanged({'a'}).affects('a'), isTrue);
    expect(const FlagsChanged({'a'}).affects('b'), isFalse);
    expect(const FlagsChanged.all().affects('anything'), isTrue);
    expect(const FlagsChanged({'a'}).keys, {'a'});
    expect(const FlagsChanged.all().keys, isNull);
  });
}
