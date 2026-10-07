import 'package:fespalier/fespalier.dart' show RouteInfo;
import 'package:flutter/widgets.dart';

/// Reads a locale tag candidate from a location; null when this location has none (since 0.10.0).
typedef LocaleOfUri = String? Function(Uri uri);

/// The tag in the URL's segment [at] (0: `/fr/products` gives `fr`), the `$lang` folder way.
///
/// The segment is a candidate: `Translations.resolve` decides whether it is a supported locale.
LocaleOfUri localeSegment({int at = 0}) => (uri) {
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  return at >= 0 && at < segments.length ? segments[at] : null;
};

/// The first of [readers] that answers.
LocaleOfUri firstLocaleOf(List<LocaleOfUri> readers) => (uri) {
  for (final reader in readers) {
    final tag = reader(uri);
    if (tag != null) return tag;
  }
  return null;
};

List<String> _segments(String template) =>
    template.split('/').where((s) => s.isNotEmpty).toList();

bool _isParam(String s) => s.startsWith(':') || s.startsWith('*');

/// Whether [segments] fit [template]: a literal is equal, `:name` is any segment, `*name` the rest.
bool _fits(List<String> template, List<String> segments) {
  for (var i = 0; i < template.length; i++) {
    final t = template[i];
    if (t.startsWith('*')) return segments.length >= i;
    if (i >= segments.length) return t.startsWith(':') && t.endsWith('?');
    if (t.startsWith(':')) continue;
    if (t != segments[i]) return false;
  }
  return template.length == segments.length;
}

/// The locale whose spellings the location uses, from the manifest's `RouteInfo.paths`
/// (`const paths = {'fr': 'produits'}`): `/produits/2` gives `fr`. A canonical-only path or a
/// spelling that two locales share gives null, and the scope keeps its previous or preferred
/// locale (since 0.10.0).
LocaleOfUri localeSpelling(Iterable<RouteInfo<Object?>> routes) {
  final localized = [
    for (final route in routes)
      if (route.paths.isNotEmpty) route,
  ];
  return (uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final found = <String>{};
    for (final route in localized) {
      for (final MapEntry(:key, :value) in route.paths.entries) {
        // A locale that keeps the canonical spelling says nothing about the language.
        if (value == route.path) continue;
        if (_fits(_segments(value), segments)) found.add(key);
      }
    }
    return found.length == 1 ? found.single : null;
  };
}

/// [uri] respelled for [to]: a locale segment at [segment] (if given) replaced, and each localized
/// level respelled through the matching `RouteInfo.pathFor(to)`. The query is kept, and non-ASCII
/// is encoded as `locationFor` does. For a language menu:
/// `context.go(relocate(uri, to: 'de', routes: AppManifest.all, segment: 0))` (since 0.10.0).
String relocate(
  Uri uri, {
  required String to,
  required Iterable<RouteInfo<Object?>> routes,
  int? segment,
}) {
  final original = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  var result = [...original];

  RouteInfo<Object?>? best;
  var bestScore = -1;
  for (final route in routes) {
    if (route.paths.isEmpty) continue;
    for (final template in {route.path, ...route.paths.values}) {
      final parts = _segments(template);
      if (!_fits(parts, original)) continue;
      final score = parts.where((p) => !_isParam(p)).length;
      if (score > bestScore) {
        best = route;
        bestScore = score;
      }
    }
  }
  if (best != null) {
    final target = _segments(best.pathFor(to));
    final next = <String>[];
    for (var i = 0; i < target.length; i++) {
      final t = target[i];
      if (t.startsWith('*')) {
        next.addAll(original.skip(i));
      } else if (t.startsWith(':')) {
        if (i < original.length) next.add(original[i]);
      } else {
        next.add(t);
      }
    }
    result = next;
  }
  if (segment != null && segment >= 0 && segment < result.length) {
    result[segment] = to;
  }
  final path = '/${result.map(Uri.encodeComponent).join('/')}';
  return uri.hasQuery ? '$path?${uri.query}' : path;
}

/// `pt-BR` gives `Locale('pt', 'BR')`, for `MaterialApp.supportedLocales` (since 0.10.0).
Locale localeFromTag(String tag) {
  final parts = tag.split(RegExp('[-_]'));
  String? script;
  String? country;
  for (final part in parts.skip(1)) {
    if (part.length == 4) {
      script = part;
    } else if (part.length == 2 || part.length == 3) {
      country ??= part.toUpperCase();
    }
  }
  return Locale.fromSubtags(
    languageCode: parts.first.toLowerCase(),
    scriptCode: script == null
        ? null
        : '${script[0].toUpperCase()}${script.substring(1).toLowerCase()}',
    countryCode: country,
  );
}
