import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

class Product {
  const Product(this.id, this.title);

  factory Product.fromJson(Map<String, dynamic> json) =>
      Product(json['id'] as int, json['title'] as String);

  final int id;
  final String title;

  Map<String, dynamic> toJson() => {'id': id, 'title': title};

  @override
  bool operator ==(Object other) =>
      other is Product && other.id == id && other.title == title;

  @override
  int get hashCode => Object.hash(id, title);
}

enum Mode { light, dark }

class Basket {
  const Basket(this.items);

  final List<Product> items;
}

class Unlisted {
  const Unlisted();
}

ExtraCodec codec({bool strict = false}) => ExtraCodec({
  Product: (toJson: (Product p) => p.toJson(), fromJson: Product.fromJson),
  Mode: (toJson: (Mode m) => m.name, fromJson: Mode.values.byName),
  Basket: (
    toJson: (Basket b) => [for (final p in b.items) p.toJson()],
    fromJson: (List<dynamic> l) => Basket([
      for (final p in l) Product.fromJson(p as Map<String, dynamic>),
    ]),
  ),
}, strict: strict);

/// What the browser's history does to the saved data: JSON text and back.
Object? viaJson(Object? saved) => jsonDecode(jsonEncode(saved));

/// What state restoration does: a standard message codec hands maps back as
/// `Map<Object?, Object?>` and lists as `List<Object?>`.
Object? viaMessages(Object? saved) => switch (saved) {
  Map() => <Object?, Object?>{
    for (final e in saved.entries) e.key: viaMessages(e.value),
  },
  List() => <Object?>[for (final v in saved) viaMessages(v)],
  _ => saved,
};

void main() {
  group('ExtraCodec', () {
    test('round-trips a registered type, tagged with its name', () {
      final c = codec();
      const product = Product(3, 'Lamp');
      final saved = c.encode(product);
      expect(saved, {
        'type': 'Product',
        'value': {'id': 3, 'title': 'Lamp'},
      });
      expect(c.decode(saved), product);
    });

    test('survives the browser history and state restoration', () {
      final c = codec();
      for (final extra in [
        const Product(1, 'a'),
        Mode.dark,
        const Basket([Product(1, 'a'), Product(2, 'b')]),
      ]) {
        for (final through in [viaJson, viaMessages]) {
          final back = c.decode(through(c.encode(extra)));
          expect(back.runtimeType, extra.runtimeType);
          expect(jsonEncode(c.encode(back)), jsonEncode(c.encode(extra)));
        }
      }
      expect(c.decode(viaJson(c.encode(Mode.dark))), Mode.dark);
    });

    test('keeps null, strings, numbers, bools and plain JSON as they are', () {
      final c = codec();
      for (final extra in <Object?>[
        null,
        'text',
        3,
        1.5,
        true,
        [
          1,
          'two',
          {'three': 3},
        ],
        {
          'a': [1, 2],
          'b': null,
        },
      ]) {
        expect(c.decode(viaJson(c.encode(extra))), extra);
        expect(c.decode(viaMessages(c.encode(extra))), extra);
      }
    });

    test('an object it doesn\'t know is saved as null, not an error', () {
      final c = codec();
      expect(c.encode(const Unlisted()), isNull);
      expect(c.encode([const Unlisted()]), isNull);
      // toJson that doesn't return JSON.
      final odd = ExtraCodec({
        Product: (
          toJson: (Product p) => DateTime(2020),
          fromJson: (Object? _) => 1,
        ),
      });
      expect(odd.encode(const Product(1, 'a')), isNull);
    });

    test('saved data that no longer reads comes back as null', () {
      final c = codec();
      expect(c.decode({'type': 'Removed', 'value': 1}), isNull);
      expect(c.decode({'type': 'Product', 'value': 'not a map'}), isNull);
      expect(
        c.decode({
          'type': 'Product',
          'value': {'id': 'x'},
        }),
        isNull,
      );
      expect(c.decode({'nothing': 'of ours'}), isNull);
      expect(c.decode(['a', 'list']), isNull);
    });

    test('strict throws where the default is null', () {
      final c = codec(strict: true);
      expect(() => c.encode(const Unlisted()), throwsArgumentError);
      expect(
        () => c.decode({'type': 'Removed', 'value': 1}),
        throwsFormatException,
      );
      expect(c.decode(c.encode(const Product(1, 'a'))), const Product(1, 'a'));
    });

    test('names give a type a name that survives minification', () {
      final c = ExtraCodec(
        {
          Product: (
            toJson: (Product p) => p.toJson(),
            fromJson: Product.fromJson,
          ),
        },
        names: {Product: 'product'},
      );
      final saved = c.encode(const Product(2, 'b'));
      expect((saved! as Map)['type'], 'product');
      expect(c.decode(saved), const Product(2, 'b'));
    });

    test('two types with one name are refused', () {
      const entry = (toJson: _toString, fromJson: _fromString);
      expect(
        () => ExtraCodec(
          {Product: entry, Mode: entry},
          names: {Product: 'x', Mode: 'x'},
        ),
        throwsArgumentError,
      );
    });

    test('works as GoRouter(extraCodec:) would use it', () {
      // go_router calls `encode` and `decode` on the codec itself.
      final Codec<Object?, Object?> c = codec();
      expect(c.decode(c.encode(const Product(9, 'z'))), const Product(9, 'z'));
      expect(c.encoder.convert(null), isNull);
      expect(c.decoder.convert(null), isNull);
    });
  });
}

Object? _toString(Object o) => '$o';
Object? _fromString(Object? o) => o;
