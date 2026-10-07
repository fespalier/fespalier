import 'package:fespalier_tolgee/src/icu.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

String f(String m, [Map<String, Object?> a = const {}, String l = 'en']) =>
    formatIcu(m, a, l);

void main() {
  test('placeholders', () {
    expect(f('Hello {name}!', {'name': 'Ada'}), 'Hello Ada!');
    expect(f('{ name }', {'name': 3}), '3');
    expect(f('Hi {name}', {}), 'Hi {name}');
    expect(f('{n}', {'n': 2.0}), '2');
  });

  test('plural with # and with the repeated {count} (Tolgee ARB form)', () {
    const hash = '{count, plural, one {# dog} other {# dogs}}';
    const repeated = '{count, plural, one {{count} dog} other {{count} dogs}}';
    for (final m in [hash, repeated]) {
      expect(f(m, {'count': 1}), '1 dog');
      expect(f(m, {'count': 5}), '5 dogs');
    }
  });

  test('=0 beats the category, offset subtracts', () {
    const m = '{n, plural, =0 {none} one {# left} other {# left}}';
    expect(f(m, {'n': 0}), 'none');
    expect(f(m, {'n': 1}), '1 left');
    const o =
        '{n, plural, offset:1 =0 {nobody} =1 {just you} other {you and # more}}';
    expect(f(o, {'n': 3}), 'you and 2 more');
    expect(f(o, {'n': 1}), 'just you');
  });

  test('select', () {
    const m = '{g, select, female {She} male {He} other {They}} left';
    expect(f(m, {'g': 'female'}), 'She left');
    expect(f(m, {'g': 'x'}), 'They left');
  });

  test('quotes', () {
    expect(f("it''s"), "it's");
    expect(f("don't"), "don't");
    expect(f("'{'not an argument'}'"), '{not an argument}');
    expect(f("{n, plural, other {'#' is # }}", {'n': 2}), '# is 2 ');
    expect(f('a # b'), 'a # b');
  });

  test('nesting', () {
    const m =
        '{g, select, other {{n, plural, one {# item for {name}} other {# items for {name}}}}}';
    expect(f(m, {'g': 'x', 'n': 2, 'name': 'Ada'}), '2 items for Ada');
  });

  test('plural categories come from intl: fr 0 is one, ru, ar', () {
    const fr = '{n, plural, one {un} other {plusieurs}}';
    expect(f(fr, {'n': 0}, 'fr'), 'un');
    expect(f(fr, {'n': 2}, 'fr'), 'plusieurs');
    const ru = '{n, plural, one {a} few {b} many {c} other {d}}';
    expect(f(ru, {'n': 1}, 'ru'), 'a');
    expect(f(ru, {'n': 3}, 'ru'), 'b');
    expect(f(ru, {'n': 5}, 'ru'), 'c');
    const ar =
        '{n, plural, zero {z} one {o} two {t} few {f} many {m} other {x}}';
    expect(f(ar, {'n': 0}, 'ar'), 'z');
    expect(f(ar, {'n': 2}, 'ar'), 't');
    expect(f(ar, {'n': 3}, 'ar'), 'f');
    expect(f(fr, {'n': 2}, 'fr-CA'), 'plusieurs');
  });

  test('malformed messages throw IcuException', () {
    for (final m in ['{', '}', '{n, plural, one {x}}', '{n, plural}', '{n,']) {
      expect(() => parseIcu(m), throwsA(isA<IcuException>()), reason: m);
    }
  });

  test('a malformed message comes back as written and is reported once', () {
    final errors = <FlutterErrorDetails>[];
    final old = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = old);
    final t = Translator('en', [
      (
        origin: TranslationOrigin.bundled,
        catalog: const Catalog('en', {'bad': 'Hello {name'}),
      ),
    ]);
    expect(t.tr('bad'), 'Hello {name');
    expect(t.tr('bad'), 'Hello {name');
    expect(errors, hasLength(1));
    expect(errors.single.library, 'fespalier_tolgee');
  });
}
