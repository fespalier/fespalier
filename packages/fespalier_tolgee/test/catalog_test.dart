import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ARB skips @ keys and @@locale, and non-strings', () {
    final c = Catalog.fromArb(
      'fr',
      '{"@@locale":"fr","a":"A","@a":{"description":"x"},"n":3}',
    );
    expect(c.locale, 'fr');
    expect(c.messages, {'a': 'A'});
  });

  test('Tolgee JSON flattens nested objects with the delimiter', () {
    const source =
        '{"cart":{"title":"Cart","items":{"one":"1"}},"flat":"F","n":4,"x":null}';
    expect(Catalog.fromJson('en', source).messages, {
      'cart.title': 'Cart',
      'cart.items.one': '1',
      'flat': 'F',
      'n': '4',
    });
    expect(Catalog.fromJson('en', '{"a":{"b":"c"}}', delimiter: '/').messages, {
      'a/b': 'c',
    });
  });

  test('bad input is a FormatException', () {
    expect(() => Catalog.fromArb('en', '[1]'), throwsFormatException);
    expect(() => Catalog.fromJson('en', 'nope'), throwsFormatException);
  });
}
