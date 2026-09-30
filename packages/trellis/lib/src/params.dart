import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Root of every params hierarchy.
///
/// A `params.dart` declares `class XParams extends <parent params>` with one
/// `final` field per `$segment` from the root down. Folders without dynamic
/// segments reuse their parent's params.
class Params {
  const Params();
}

/// What `guard.dart` returns: `null` lets navigation through, a location
/// redirects (typed routes give you `.location`).
typedef GuardResult = FutureOr<String?>;

/// Thrown when a path segment can't be parsed into its declared type.
/// The generated code turns it into the root `not_found.dart`.
final class BadParam implements Exception {
  const BadParam(this.name, this.value, this.type);

  final String name;
  final String? value;
  final String type;

  @override
  String toString() => 'BadParam: \$$name = "$value" is not a valid $type';
}

/// Typed readers for path segments, used by generated code.
abstract final class Segment {
  static String asString(GoRouterState s, String name) =>
      s.pathParameters[name] ?? (throw BadParam(name, null, 'String'));

  static int asInt(GoRouterState s, String name) {
    final raw = asString(s, name);
    return int.tryParse(raw) ?? (throw BadParam(name, raw, 'int'));
  }

  static double asDouble(GoRouterState s, String name) {
    final raw = asString(s, name);
    return double.tryParse(raw) ?? (throw BadParam(name, raw, 'double'));
  }

  static bool asBool(GoRouterState s, String name) => switch (asString(s, name)) {
        'true' => true,
        'false' => false,
        final raw => throw BadParam(name, raw, 'bool'),
      };
}

/// Cache key for a route's data provider.
///
/// Equality is the resolved path only (`/products/42`), so user params
/// classes never need `==`/`hashCode`.
@immutable
final class RouteKey<P> {
  const RouteKey(this.path, this.params);

  final String path;
  final P params;

  @override
  bool operator ==(Object other) =>
      other is RouteKey<P> && other.path == path;

  @override
  int get hashCode => Object.hash(RouteKey, path);

  @override
  String toString() => 'RouteKey($path)';
}

/// Generated builders call this: parse params, or fall back to not-found.
Widget buildWithParams<P>(
  P Function() parse,
  Widget Function(P params) build,
  Widget Function() notFound,
) {
  final P params;
  try {
    params = parse();
  } on BadParam {
    return notFound();
  }
  return build(params);
}

/// Generated redirects call this: unparsable params skip the guard and let
/// the builder show not-found.
FutureOr<String?> guardWithParams<P>(
  P Function() parse,
  GuardResult Function(P params) guard,
) {
  final P params;
  try {
    params = parse();
  } on BadParam {
    return null;
  }
  return guard(params);
}
