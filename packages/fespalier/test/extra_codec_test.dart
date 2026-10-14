import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
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

/// What freezed makes of `const factory Note(...) = _Note`: the class you write
/// is abstract, and every object of it is a private subclass (so
/// `Note(...).runtimeType` is `_Note`, never `Note`).
abstract class Note {
  const Note._();

  const factory Note({required int id, required String title}) = _Note;

  factory Note.fromJson(Map<String, dynamic> json) =>
      Note(id: json['id'] as int, title: json['title'] as String);

  int get id;
  String get title;

  Map<String, dynamic> toJson() => {'id': id, 'title': title};

  @override
  bool operator ==(Object other) =>
      other is Note && other.id == id && other.title == title;

  @override
  int get hashCode => Object.hash(id, title);
}

class _Note extends Note {
  const _Note({required this.id, required this.title}) : super._();

  @override
  final int id;
  @override
  final String title;
}

/// A family: `Circle` is more specific than `Shape`, and both are abstract, each
/// built through a private subclass the way freezed builds a union's cases.
abstract class Shape {
  const Shape();

  Map<String, dynamic> toJson();
}

abstract class Circle extends Shape {
  const Circle._();

  const factory Circle(int r) = _Circle;

  factory Circle.fromJson(Map<String, dynamic> json) =>
      Circle(json['r'] as int);

  int get r;
}

class _Circle extends Circle {
  const _Circle(this.r) : super._();

  @override
  final int r;

  @override
  Map<String, dynamic> toJson() => {'r': r};
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
  // What a debug build prints about an extra no entry takes is collected, not
  // shown: the tests that save one would fill the output.
  late DebugPrintCallback printed;
  late List<String> lines;

  setUp(() {
    printed = debugPrint;
    lines = [];
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
  });

  tearDown(() => debugPrint = printed);

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

  group('ExtraCodec.of, for the private classes freezed makes', () {
    ExtraCodec noteCodec({bool strict = false}) => ExtraCodec.of([
      ExtraType<Note>(toJson: (n) => n.toJson(), fromJson: Note.fromJson),
      ExtraType<Mode>(toJson: (m) => m.name, fromJson: Mode.values.byName),
    ], strict: strict);

    test('an object of a private subclass is a _Note, not a Note', () {
      const note = Note(id: 3, title: 'Lamp');
      expect(note.runtimeType.toString(), '_Note');
      expect(note.runtimeType, isNot(Note));
      // The exact-type constructor looks the type up as written: a `Note`
      // entry never matches, and the extra is saved as null (debug builds say
      // so, see below).
      final exact = ExtraCodec({
        Note: (toJson: (Note n) => n.toJson(), fromJson: Note.fromJson),
      });
      expect(exact.encode(note), isNull);
    });

    test('round-trips through the browser history and state restoration', () {
      final c = noteCodec();
      const note = Note(id: 3, title: 'Lamp');
      final saved = c.encode(note);
      expect(saved, {
        'type': 'Note',
        'value': {'id': 3, 'title': 'Lamp'},
      });
      for (final through in [viaJson, viaMessages]) {
        final back = c.decode(through(saved));
        expect(back, note);
        expect(back.runtimeType.toString(), '_Note');
      }
      expect(c.decode(viaJson(c.encode(Mode.dark))), Mode.dark);
    });

    test('keeps null, strings, numbers, bools and plain JSON as they are', () {
      final c = noteCodec();
      for (final extra in <Object?>[
        null,
        'text',
        3,
        true,
        [
          1,
          {'a': null},
        ],
      ]) {
        expect(c.decode(viaJson(c.encode(extra))), extra);
      }
    });

    test('the first entry the object is an instance of takes it', () {
      const circle = Circle(2);
      Map<String, dynamic> any(Shape s) => {'shape': 'any'};
      Circle read(Map<String, dynamic> j) => Circle(j['r'] as int);

      final specificFirst = ExtraCodec.of([
        ExtraType<Circle>(toJson: (c) => c.toJson(), fromJson: read),
        ExtraType<Shape>(toJson: any, fromJson: read),
      ]);
      expect(specificFirst.encode(circle), {
        'type': 'Circle',
        'value': {'r': 2},
      });
      expect(specificFirst.decode(specificFirst.encode(circle)), isA<Circle>());

      // Shape first: it shadows Circle, so the same object is saved as a Shape.
      final generalFirst = ExtraCodec.of([
        ExtraType<Shape>(toJson: any, fromJson: read),
        ExtraType<Circle>(toJson: (c) => c.toJson(), fromJson: read),
      ]);
      expect(generalFirst.encode(circle), {
        'type': 'Shape',
        'value': {'shape': 'any'},
      });
    });

    test('one entry covers a family, and a name survives minification', () {
      final c = ExtraCodec.of([
        ExtraType<Shape>(
          toJson: (s) => s.toJson(),
          fromJson: (Map<String, dynamic> j) => Circle(j['r'] as int),
          name: 'shape',
        ),
      ]);
      final saved = c.encode(const Circle(5));
      expect((saved! as Map)['type'], 'shape');
      expect((c.decode(viaJson(saved))! as Circle).r, 5);
    });

    test('an object no entry takes is null, and strict throws', () {
      final c = noteCodec();
      expect(c.encode(const Unlisted()), isNull);
      expect(c.encode(const Product(1, 'a')), isNull);
      expect(c.decode({'type': 'Removed', 'value': 1}), isNull);
      expect(c.decode({'type': 'Note', 'value': 'not a map'}), isNull);

      final strict = noteCodec(strict: true);
      expect(() => strict.encode(const Unlisted()), throwsArgumentError);
      expect(
        () => strict.decode({'type': 'Removed', 'value': 1}),
        throwsFormatException,
      );
      expect(
        strict.decode(strict.encode(const Note(id: 1, title: 'a'))),
        const Note(id: 1, title: 'a'),
      );
    });

    test('two entries with one name are refused, and name: solves it', () {
      Note read(Map<String, dynamic> j) => Note.fromJson(j);
      expect(
        () => ExtraCodec.of([
          ExtraType<Note>(toJson: (n) => n.toJson(), fromJson: read),
          ExtraType<Note>(toJson: (n) => n.toJson(), fromJson: read),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('with `name:`'),
          ),
        ),
      );
      final named = ExtraCodec.of([
        ExtraType<Note>(toJson: (n) => n.toJson(), fromJson: read),
        ExtraType<Note>(toJson: (n) => n.toJson(), fromJson: read, name: 'n2'),
      ]);
      expect(
        (named.encode(const Note(id: 1, title: 'a'))! as Map)['type'],
        'Note',
      );
    });

    test('works as GoRouter(extraCodec:) would use it', () {
      final Codec<Object?, Object?> c = noteCodec();
      const note = Note(id: 9, title: 'z');
      expect(c.decode(c.encode(note)), note);
      expect(c.encoder.convert(null), isNull);
      expect(c.decoder.convert(null), isNull);
    });
  });

  group('the debug line for an extra with no entry', () {
    test('says what to register, once per type, and still saves null', () {
      final c = codec();
      expect(c.encode(const Note(id: 1, title: 'a')), isNull);
      expect(c.encode(const Note(id: 2, title: 'b')), isNull);
      expect(c.encode(const Unlisted()), isNull);
      expect(c.encode(const Unlisted()), isNull);
      expect(lines, hasLength(2));
      // A private class is what freezed's factory syntax makes.
      expect(lines[0], contains("a _Note isn't registered in the ExtraCodec"));
      expect(lines[0], contains('ExtraCodec.of([ExtraType<Note>(...)])'));
      expect(lines[0], contains('saved as null'));
      expect(lines[1], contains("a Unlisted isn't registered"));
      expect(lines[1], contains('ExtraType<Unlisted>('));
    });

    test(
      'is the same for ExtraCodec.of, and says nothing for a type it has',
      () {
        final c = ExtraCodec.of([
          ExtraType<Mode>(toJson: (m) => m.name, fromJson: Mode.values.byName),
        ]);
        expect(c.encode(Mode.dark), isNotNull);
        expect(c.encode(const Note(id: 1, title: 'a')), isNull);
        expect(lines, hasLength(1));
      },
    );

    test('is not printed for what needs no entry, nor under strict', () {
      final c = codec();
      for (final extra in <Object?>[
        null,
        'x',
        1,
        true,
        [1],
        {'a': 1},
      ]) {
        c.encode(extra);
      }
      expect(
        () => codec(strict: true).encode(const Unlisted()),
        throwsArgumentError,
      );
      expect(lines, isEmpty);
    });

    test('strict names the private class in its error', () {
      expect(
        () => codec(strict: true).encode(const Note(id: 1, title: 'a')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('ExtraType<Note>'),
          ),
        ),
      );
    });
  });
}

Object? _toString(Object o) => '$o';
Object? _fromString(Object? o) => o;
