import 'dart:convert';

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
/// - An object is found by its exact runtime type: register each subclass of a
///   sealed class, not the class.
/// - Nothing here crashes navigation. An object of a type that isn't
///   registered is saved as `null`, and saved data that no longer reads (a
///   type that was removed or renamed since, a `fromJson` that throws) comes
///   back as `null`. A page treats `extra` as a shortcut, never the source of
///   truth, so `null` is always something it can show. Pass `strict: true` in
///   tests to throw instead and catch a type you forgot to register.
/// - The name is the type's `toString()`, which a release build for the web
///   minifies: stable while a build runs, different in the next. To keep saved
///   data readable across deployments, name the types yourself with [names].
final class ExtraCodec extends Codec<Object?, Object?> {
  /// [types] maps each type to how it is saved. [names] gives a type a name of
  /// its own in the saved data instead of `Type.toString()`.
  ExtraCodec(
    Map<Type, ExtraJson> types, {
    Map<Type, String> names = const {},
    this.strict = false,
  }) : _byType = {
         for (final MapEntry(:key, :value) in types.entries)
           key: _Entry(names[key] ?? key.toString(), value),
       } {
    final seen = <String>{};
    for (final e in _byType.values) {
      if (e.name == _jsonName || !seen.add(e.name)) {
        throw ArgumentError(
          'two types are saved as `${e.name}`: give one of them another name '
          'with `names:`',
        );
      }
    }
    _byName = {for (final e in _byType.values) e.name: e};
  }

  /// Throw for a type that isn't registered and for saved data that can't be
  /// read, instead of using `null`.
  final bool strict;

  final Map<Type, _Entry> _byType;
  late final Map<String, _Entry> _byName;

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
    final entry = _byType[extra.runtimeType];
    if (entry == null) {
      if (_isJson(extra)) return _tagged(_jsonName, extra);
      if (strict) {
        throw ArgumentError.value(
          extra,
          'extra',
          'a ${extra.runtimeType} isn\'t registered in the ExtraCodec',
        );
      }
      return null;
    }
    final json = (entry.json.toJson as dynamic)(extra);
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
      return (entry.json.fromJson as dynamic)(value);
    } on Object {
      if (strict) rethrow;
      return null;
    }
  }

  static Map<String, Object?> _tagged(String name, Object? value) => {
    'type': name,
    'value': value,
  };
}

class _Entry {
  const _Entry(this.name, this.json);
  final String name;
  final ExtraJson json;
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
