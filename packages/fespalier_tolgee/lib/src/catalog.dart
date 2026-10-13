import 'dart:convert';

import 'package:flutter/foundation.dart';

/// One locale's messages: key to ICU message (the ARB subset: `{name}`, plural, select, `#`,
/// quoting). Immutable (since 0.10.0).
@immutable
final class Catalog {
  /// A catalog for [locale] (a tag: `fr`, `pt-BR`) holding [messages].
  const Catalog(this.locale, this.messages);

  /// An `.arb` file: `@key` metadata and `@@locale` are skipped, every other string entry is a message.
  ///
  /// Throws a [FormatException] when [source] is not a JSON object.
  factory Catalog.fromArb(String locale, String source) {
    final json = _object(source);
    return Catalog(locale, {
      for (final MapEntry(:key, :value) in json.entries)
        if (!key.startsWith('@') && value is String) key: value,
    });
  }

  /// Tolgee JSON, nested or flat: nested objects become dotted keys (`cart.title`), joined with
  /// [delimiter]. Numbers and booleans are kept as their text; `null`s and lists are skipped.
  ///
  /// Throws a [FormatException] when [source] is not a JSON object.
  factory Catalog.fromJson(
    String locale,
    String source, {
    String delimiter = '.',
  }) {
    final messages = <String, String>{};
    void walk(String prefix, Map<String, Object?> map) {
      for (final MapEntry(:key, :value) in map.entries) {
        final name = prefix.isEmpty ? key : '$prefix$delimiter$key';
        if (value is String) {
          messages[name] = value;
        } else if (value is num || value is bool) {
          messages[name] = '$value';
        } else if (value is Map<String, Object?>) {
          walk(name, value);
        }
      }
    }

    walk('', _object(source));
    return Catalog(locale, messages);
  }

  static Map<String, Object?> _object(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('A catalog is a JSON object');
    }
    return decoded;
  }

  /// The locale tag these messages are in.
  final String locale;

  /// Key to ICU message.
  final Map<String, String> messages;

  /// This catalog's messages as JSON, for the cache.
  String toJson() => jsonEncode(messages);
}
