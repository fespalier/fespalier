import 'dart:async';

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
  /// The address bar and the browser's history follow on the web: when the page on top
  /// is a route of the declarative stack, the entry is replaced (no new history entry)
  /// and shows this location, see [replaceLocation]. Over a page that was pushed it is
  /// go_router's `replace`, which keeps the pushed stack.
  ///
  /// The optional [locale] picks one of the route's localized spellings.
  void replace(BuildContext context, {String? locale}) =>
      replaceLocation(context, locationFor(locale));

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

/// Replaces the current location with [location], as `TypedLocation.replace` does.
///
/// When the page on top of the stack is part of the declarative stack (it was
/// reached by `go`, a link or the address bar), it is `GoRouter.go` inside
/// `Router.neglect`: the location is the router's `uri`, so the browser's address bar
/// shows it, and the browser replaces its history entry instead of adding one. A page
/// keeps its state, because go_router keys it by its path template. Everything below
/// the top becomes the stack that [location] has by itself.
///
/// When the page on top was pushed (`push`), it is `GoRouter.replace`, because a `go`
/// would drop the pushed stack. go_router shows that location in the address bar only
/// when `GoRouter.optionURLReflectsImperativeAPIs` is true (the pubspec's
/// `push_updates_url: true` sets it).
///
/// [extra] goes to the new location, as for `go`. The answer of `GoRouter.replace`
/// (what the page pops with) is not given: nothing waits on a replaced page.
void replaceLocation(BuildContext context, String location, {Object? extra}) {
  final router = GoRouter.of(context);
  final top = router.routerDelegate.currentConfiguration.lastOrNull;
  if (top is ImperativeRouteMatch) {
    unawaited(router.replace<Object?>(location, extra: extra));
  } else {
    Router.neglect(context, () => router.go(location, extra: extra));
  }
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
