import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

/// How one type of `extra` is saved and read back: [toJson] turns the object
/// into JSON-like data (`null`, `String`, `num`, `bool`, and lists and maps of
/// them), [fromJson] builds it again.
///
/// Annotate the parameter of the function that takes the object, and let the
/// constructor tear-off do the other:
///
/// ```dart
/// Product: (toJson: (Product p) => p.toJson(), fromJson: Product.fromJson),
/// ```
///
/// (The parameters are `Never` here so any `Product Function(Map<String,
/// dynamic>)` fits; [ExtraCodec] only ever calls each with its own type.)
typedef ExtraJson = ({
  Object? Function(Never) toJson,
  Object? Function(Never) fromJson,
});

/// A `Codec` for `GoRouter(extraCodec:)`, built from the types an app passes
/// as `extra`.
///
/// go_router keeps a navigation's `extra` next to its location for browser
/// history and state restoration, and can only save what is JSON: anything
/// else is dropped, so after a reload on the web a page gets `null`. This
/// codec saves an object under the name of its type and builds it again with
/// that type's `fromJson`:
///
/// ```dart
/// // lib/app/extra_codec.dart: `fsp gen` hands it to `AppRoutes.router()`.
/// final extraCodec = ExtraCodec({
///   Product: (toJson: (Product p) => p.toJson(), fromJson: Product.fromJson),
///   Mode: (toJson: (Mode m) => m.name, fromJson: Mode.values.byName),
/// });
/// ```
///
/// - `null`, `String`, `num`, `bool` and plain JSON lists and maps of them are
///   saved as they are, so an app that passes them needs no entry.
/// - This constructor finds an object by its exact runtime type, so it never
///   matches a subclass: register each subclass of a sealed class, not the
///   class. A class that freezed makes from `const factory Note(...) = _Note`
///   is one of those, and an object of it is a private `_Note`, not a `Note`.
///   Use [ExtraCodec.of] for those: it matches with `is`.
/// - Nothing here crashes navigation. An object of a type that isn't
///   registered is saved as `null` (in a debug build one line says so, once per
///   type), and saved data that no longer reads (a type that was removed or
///   renamed since, a `fromJson` that throws) comes back as `null`. A page
///   treats `extra` as a shortcut, never the source of truth, so `null` is
///   always something it can show. Pass `strict: true` in tests to throw
///   instead and catch a type you forgot to register.
/// - The name is the type's `toString()`, which a release build for the web
///   minifies: stable while a build runs, different in the next. To keep saved
///   data readable across deployments, name the types yourself with [names]
///   (with [ExtraCodec.of], [ExtraType.name]).
final class ExtraCodec extends Codec<Object?, Object?> {
  /// [types] maps each type to how it is saved. [names] gives a type a name of
  /// its own in the saved data instead of `Type.toString()`.
  ExtraCodec(
    Map<Type, ExtraJson> types, {
    Map<Type, String> names = const {},
    bool strict = false,
  }) : this._(
         exact: {
           for (final MapEntry(:key, :value) in types.entries)
             key: _Entry(
               names[key] ?? key.toString(),
               (o) => (value.toJson as dynamic)(o),
               (json) => (value.fromJson as dynamic)(json),
             ),
         },
         ordered: const [],
         strict: strict,
       );

  /// An `ExtraCodec` that finds an object with `is`: the first of [types], in
  /// the order written, that the object is an instance of (since 0.16.0).
  ///
  /// The exact-type constructor never matches a private subclass, and freezed
  /// makes one for every `const factory Note(...) = _Note`: a `Note` you build
  /// is a `_Note`, so a lookup of `Note` finds nothing and the extra is saved
  /// as `null`. Here an [ExtraType] for `Note` takes it:
  ///
  /// ```dart
  /// final extraCodec = ExtraCodec.of([
  ///   ExtraType<Note>(toJson: (n) => n.toJson(), fromJson: Note.fromJson),
  ///   ExtraType<Shape>(toJson: (s) => s.toJson(), fromJson: Shape.fromJson),
  /// ]);
  /// ```
  ///
  /// - **The order matters.** An object is saved as the first entry it is an
  ///   instance of, so put the most specific type first: with `Shape` before
  ///   `Circle`, a `Circle` is saved as a `Shape` and read back by
  ///   `Shape.fromJson`.
  /// - One entry covers a whole family: an `ExtraType<Shape>` takes every
  ///   subclass of a sealed `Shape`, with a `fromJson` that picks the subclass.
  /// - Nothing else differs from the default constructor: the same names
  ///   (`ExtraType.name`), the same [strict], the same `null` for what it
  ///   can't save or read.
  ExtraCodec.of(Iterable<ExtraType<Object>> types, {bool strict = false})
    : this._(
        exact: const {},
        ordered: [for (final t in types) t._entry()],
        strict: strict,
      );

  ExtraCodec._({
    required Map<Type, _Entry> exact,
    required List<_Entry> ordered,
    required this.strict,
  }) : _byType = exact,
       _ordered = ordered {
    final seen = <String>{};
    for (final e in [..._byType.values, ..._ordered]) {
      if (e.name == _jsonName || !seen.add(e.name)) {
        throw ArgumentError(
          'two types are saved as `${e.name}`: give one of them another name '
          'with `${_ordered.isEmpty ? 'names' : 'name'}:`',
        );
      }
    }
    _byName = {
      for (final e in [..._byType.values, ..._ordered]) e.name: e,
    };
  }

  /// Throw for a type that isn't registered and for saved data that can't be
  /// read, instead of using `null`.
  final bool strict;

  final Map<Type, _Entry> _byType;
  final List<_Entry> _ordered;
  late final Map<String, _Entry> _byName;

  /// The runtime types a debug build has already said it can't save, so that
  /// it says it once. Never read in a release build.
  final Set<Type> _reported = {};

  /// The name plain JSON collections are saved under.
  static const _jsonName = '#json';

  @override
  Converter<Object?, Object?> get encoder => _Encoder(this);

  @override
  Converter<Object?, Object?> get decoder => _Decoder(this);

  Object? _encode(Object? extra) {
    if (extra == null || extra is String || extra is num || extra is bool) {
      return extra;
    }
    final entry = _find(extra);
    if (entry == null) {
      if (_isJson(extra)) return _tagged(_jsonName, extra);
      if (strict) {
        throw ArgumentError.value(extra, 'extra', _unregistered(extra));
      }
      if (kDebugMode && _reported.add(extra.runtimeType)) {
        debugPrint(
          'fespalier: ${_unregistered(extra)} (until then this extra is saved '
          'as null, so a reload gives the page null)',
        );
      }
      return null;
    }
    final json = entry.save(extra);
    if (!_isJson(json)) {
      if (strict) {
        throw ArgumentError.value(
          extra,
          'extra',
          'toJson for ${entry.name} returned ${json.runtimeType}, not JSON',
        );
      }
      return null;
    }
    return _tagged(entry.name, json);
  }

  Object? _decode(Object? saved) {
    if (saved == null || saved is String || saved is num || saved is bool) {
      return saved;
    }
    try {
      if (saved is! Map) throw FormatException('not an extra: $saved');
      final name = saved['type'];
      final value = _plain(saved['value']);
      if (name == _jsonName) return value;
      final entry = _byName[name];
      if (entry == null) throw FormatException('no type called `$name`');
      return entry.load(value);
    } on Object {
      if (strict) rethrow;
      return null;
    }
  }

  /// The entry that saves [extra]: for [ExtraCodec.new] the one for its exact
  /// runtime type, for [ExtraCodec.of] the first one it is an instance of.
  _Entry? _find(Object extra) {
    final exact = _byType[extra.runtimeType];
    if (exact != null) return exact;
    for (final e in _ordered) {
      if (e.accepts(extra)) return e;
    }
    return null;
  }

  /// What a debug build and `strict` say about an object no entry takes. A
  /// private runtime type (`_Note`) is what freezed's factory syntax makes.
  static String _unregistered(Object extra) {
    final type = extra.runtimeType.toString();
    final how = type.startsWith('_')
        ? 'it is a private class, such as freezed makes for `const factory '
              'Note(...) = _Note`; register its public type with '
              '`ExtraCodec.of([ExtraType<Note>(...)])`'
        : 'register it with `ExtraCodec.of([ExtraType<$type>(toJson: ..., '
              'fromJson: ...)])`, or as `$type` in `ExtraCodec({...})`';
    return 'a $type isn\'t registered in the ExtraCodec; $how';
  }

  static Map<String, Object?> _tagged(String name, Object? value) => {
    'type': name,
    'value': value,
  };
}

/// How one type of extra is saved, whichever constructor made it.
class _Entry {
  const _Entry(this.name, this.save, this.load, {this.accepts = _never});

  final String name;

  /// `toJson` of an object this entry takes.
  final Object? Function(Object) save;

  /// `fromJson` of saved data.
  final Object? Function(Object?) load;

  /// Whether this entry takes an object, for [ExtraCodec.of]. The exact-type
  /// constructor finds its entries by type and never asks.
  final bool Function(Object) accepts;

  static bool _never(Object _) => false;
}

/// One type that [ExtraCodec.of] saves, and how (since 0.16.0): [toJson] turns
/// an object into JSON-like data (`null`, `String`, `num`, `bool`, and lists
/// and maps of them), [fromJson] builds it again.
///
/// It takes every object that `is` a [T], so [T] may be the abstract class a
/// freezed class is declared as, or the root of a sealed family:
///
/// ```dart
/// ExtraType<Note>(toJson: (n) => n.toJson(), fromJson: Note.fromJson),
/// ```
///
/// [toJson]'s parameter is a [T], so a closure needs no annotation. Let a
/// constructor tear-off do [fromJson] (`Note.fromJson`), or annotate the
/// parameter of a closure: it is a `Never` here so that any
/// `Note Function(Map<String, dynamic>)` fits, and [ExtraCodec] only ever
/// calls it with what it read.
final class ExtraType<T extends Object> {
  /// An entry for every object that is a [T]. [name] is what the saved data
  /// calls it (default `T.toString()`, which a release build for the web
  /// minifies: give a name to keep saved data readable across deployments).
  const ExtraType({required this.toJson, required this.fromJson, this.name});

  /// Turns an object into JSON-like data.
  final Object? Function(T value) toJson;

  /// Builds an object from what [toJson] returned, as it comes back from the
  /// browser's history or state restoration (maps are `Map<String, dynamic>`).
  final T Function(Never json) fromJson;

  /// The name in the saved data; `T.toString()` when null.
  final String? name;

  _Entry _entry() => _Entry(
    name ?? '$T',
    (o) => toJson(o as T),
    (json) => (fromJson as dynamic)(json),
    accepts: (o) => o is T,
  );
}

class _Encoder extends Converter<Object?, Object?> {
  const _Encoder(this._codec);
  final ExtraCodec _codec;

  @override
  Object? convert(Object? input) => _codec._encode(input);
}

class _Decoder extends Converter<Object?, Object?> {
  const _Decoder(this._codec);
  final ExtraCodec _codec;

  @override
  Object? convert(Object? input) => _codec._decode(input);
}

/// Whether [value] is JSON: what the browser's history and the restoration
/// data can hold.
bool _isJson(Object? value) => switch (value) {
  null || String() || num() || bool() => true,
  List<Object?>() => value.every(_isJson),
  Map<Object?, Object?>() =>
    value.keys.every((k) => k is String) && value.values.every(_isJson),
  _ => false,
};

/// Saved data as `fromJson` expects to read it: maps are `Map<String, dynamic>`
/// and lists `List<dynamic>`, whatever the platform gave back (restoration
/// hands back `Map<Object?, Object?>`, the browser its own).
Object? _plain(Object? value) => switch (value) {
  Map<Object?, Object?>() => <String, dynamic>{
    for (final MapEntry(:key, :value) in value.entries)
      key as String: _plain(value),
  },
  List<Object?>() => <dynamic>[for (final v in value) _plain(v)],
  _ => value,
};
