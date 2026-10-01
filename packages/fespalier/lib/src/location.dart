import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'route_data.dart';

/// Base of every generated route class (`ProductRoute(id: 42)`).
abstract class TypedLocation {
  /// Creates a location; subclasses are `const` too.
  const TypedLocation();

  /// Full location, including the mount prefix, in the canonical spelling: the
  /// folders' names (`/products/42`), whatever [locationFor] could say.
  String get location;

  /// The location with every localized path segment spelled as [locale] has it:
  /// `ProductRoute(id: 42).locationFor('fr')` is `/produits/42` when
  /// `products/route.dart` says `const paths = {'fr': 'produits'};`.
  ///
  /// A segment with no spelling for [locale] keeps its canonical one, so a `null` or
  /// unknown locale gives [location]. A tag with a region falls back to its language
  /// (`fr-CA` is `fr`). Routes without a localized segment always answer [location].
  String locationFor(String? locale) => location;

  /// Goes to this route; [locale] picks the spelling of its localized segments
  /// (see [locationFor]), the canonical one by default.
  void go(BuildContext context, {String? locale}) =>
      context.go(locationFor(locale));

  /// Pushes this location onto the stack and completes with what the page pops with.
  ///
  /// The optional [locale] picks one of the route's localized spellings.
  Future<T?> push<T extends Object?>(BuildContext context, {String? locale}) =>
      context.push<T>(locationFor(locale));

  /// Replaces the current location with this one.
  ///
  /// The optional [locale] picks one of the route's localized spellings.
  void replace(BuildContext context, {String? locale}) =>
      context.replace(locationFor(locale));

  /// Starts loading every `data.dart` the page at this location reads (the
  /// data of each section above it, then its own: what `AppRoutes.dataAt`
  /// answers for [location]) and keeps them alive until the returned handle is
  /// closed, so the page shows at once when it is reached. `keepFor` closes it
  /// after that long, as for `prefetch`.
  ///
  /// It never navigates and never runs a guard or a redirect. A route without
  /// data, like this base, returns a closed handle: there is nothing to warm.
  /// `RouteLink` calls it to preload.
  PrefetchHandle preload(WidgetRef ref, {Duration? keepFor}) =>
      ref.prefetchAll(const [], keepFor: keepFor);
}

/// Joins a mount prefix (`/shop`) and a route path (`/products/42`).
String joinLocation(String base, String path) {
  if (base.isEmpty || base == '/') return path;
  final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  return path == '/' ? b : '$b$path';
}

/// Whether two locale tags are the same: without regard to case, and `_` is `-`
/// (`fr_CA` is `fr-ca`).
bool sameLocale(String a, String b) =>
    a.replaceAll('_', '-').toLowerCase() ==
    b.replaceAll('_', '-').toLowerCase();

/// The spelling of one localized path segment in [locale], which a generated
/// `locationFor` calls for each one. [spellings] is the folder's `paths` (locale
/// tag to spelling, as written: `'über'`) and [canonical] the folder's name, for a
/// locale it has no entry for. A tag with a region (`fr-CA`) falls back to its
/// language (`fr`) when it has no entry of its own.
///
/// The result is ready to go in a location: a spelling with letters beyond ASCII is
/// percent-encoded, as `Uri` writes a path (`über` is `%C3%BCber`).
String localizedSegment(
  String? locale,
  String canonical,
  Map<String, String> spellings,
) {
  if (locale == null || locale.isEmpty) return canonical;
  final language = locale.split(RegExp('[-_]')).first;
  String? fallback;
  for (final MapEntry(:key, :value) in spellings.entries) {
    if (sameLocale(key, locale)) return Uri.encodeComponent(value);
    if (sameLocale(key, language)) fallback = value;
  }
  return fallback == null ? canonical : Uri.encodeComponent(fallback);
}
