import 'package:flutter/foundation.dart';

import 'catalog.dart';
import 'icu.dart';
import 'report.dart';

/// Where a key's text came from, for the in-context panel and for tests (since 0.10.0).
enum TranslationOrigin {
  /// Edited in the in-context panel (debug builds only).
  edited,

  /// Fetched from the remote source in this run.
  remote,

  /// A remote catalog read back from the cache.
  cached,

  /// Shipped in the app.
  bundled,

  /// Found in the catalog of the locale's language or of the base locale.
  fallbackLocale,

  /// No catalog has it: the key is shown.
  missing,
}

/// One link of a translator's chain: [catalog] and where it came from.
typedef TranslatorLayer = ({TranslationOrigin origin, Catalog catalog});

/// The fallback chain for one locale, resolved: what `context.tr` and `ref.watch(translator(..))`
/// read (since 0.10.0). Synchronous.
@immutable
final class Translator {
  /// A translator for [locale] reading [layers] in order (first wins). [onMissing] hears each key
  /// that [tr] could not find.
  Translator(
    this.locale,
    List<TranslatorLayer> layers, {
    void Function(String locale, String key)? onMissing,
  }) : _layers = List.unmodifiable(layers),
       _onMissing = onMissing;

  /// A translator that has nothing: every key is itself.
  Translator.empty([String locale = '']) : this(locale, const []);

  /// The tag this translator answers for (resolved: `fr-CA` when bundled, else `fr`, else the base).
  final String locale;

  final List<TranslatorLayer> _layers;
  final void Function(String locale, String key)? _onMissing;

  // Parsed messages and the malformed ones already reported: caches, not state.
  final _parsed = <String, List<IcuNode>?>{};
  final _reported = <String>{};

  TranslatorLayer? _find(String key) {
    for (final layer in _layers) {
      if (layer.catalog.messages.containsKey(key)) return layer;
    }
    return null;
  }

  /// [key] formatted with [args]. The first catalog in the chain that has it wins: edited (debug
  /// only), then remote or cached, then bundled, for the locale, then its language, then the base
  /// locale, then [key] itself. Never throws: a malformed message is returned as written (and
  /// reported once, in debug).
  String tr(String key, [Map<String, Object?> args = const {}]) {
    final text = maybeTr(key, args);
    if (text != null) return text;
    _onMissing?.call(locale, key);
    return key;
  }

  /// Like [tr], or null when no catalog in the chain has [key].
  String? maybeTr(String key, [Map<String, Object?> args = const {}]) {
    final layer = _find(key);
    if (layer == null) return null;
    final message = layer.catalog.messages[key]!;
    final cache = _parsed;
    final List<IcuNode>? nodes;
    if (cache.containsKey(message)) {
      nodes = cache[message];
    } else {
      List<IcuNode>? parsed;
      try {
        parsed = parseIcu(message);
      } on IcuException catch (e) {
        parsed = null;
        if (kDebugMode) {
          if (_reported.add(key)) {
            reportProblem(
              FormatException(
                'Malformed message for "$key": ${e.message}',
                message,
                e.offset,
              ),
              context: 'while formatting a translation',
            );
          }
        }
      }
      cache[message] = parsed;
      nodes = parsed;
    }
    if (nodes == null) return message;
    return formatNodes(nodes, args, layer.catalog.locale);
  }

  /// The ICU message under [key] as written, before formatting; null when no catalog has it.
  String? messageOf(String key) => _find(key)?.catalog.messages[key];

  /// Whether [other] answers for the same locale from the very same catalogs, in the same order.
  bool sameLayersAs(Translator other) {
    if (locale != other.locale ||
        _onMissing != other._onMissing ||
        _layers.length != other._layers.length) {
      return false;
    }
    for (var i = 0; i < _layers.length; i++) {
      if (_layers[i].origin != other._layers[i].origin ||
          !identical(
            _layers[i].catalog.messages,
            other._layers[i].catalog.messages,
          )) {
        return false;
      }
    }
    return true;
  }

  /// Whether any catalog in the chain has [key].
  bool has(String key) => _find(key) != null;

  /// Which link of the chain answers [key].
  TranslationOrigin originOf(String key) {
    final layer = _find(key);
    if (layer == null) return TranslationOrigin.missing;
    if (layer.origin != TranslationOrigin.edited &&
        layer.catalog.locale != locale) {
      return TranslationOrigin.fallbackLocale;
    }
    return layer.origin;
  }
}
