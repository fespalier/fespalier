import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// What `guard.dart` returns: `null` lets navigation through, a location
/// redirects (typed routes give you `.location`).
typedef GuardResult = FutureOr<String?>;

/// Thrown when a path segment can't be parsed into its declared type.
/// The generated code turns it into the root `not_found.dart`.
final class BadSegment implements Exception {
  const BadSegment(this.name, this.value, this.type);

  final String name;
  final String? value;
  final String type;

  @override
  String toString() => 'BadSegment: \$$name = "$value" is not a valid $type';
}

/// Typed readers for path segments, used by generated code.
abstract final class Segment {
  static String asString(GoRouterState s, String name) =>
      s.pathParameters[name] ?? (throw BadSegment(name, null, 'String'));

  static int asInt(GoRouterState s, String name) {
    final raw = asString(s, name);
    return int.tryParse(raw) ?? (throw BadSegment(name, raw, 'int'));
  }

  static double asDouble(GoRouterState s, String name) {
    final raw = asString(s, name);
    return double.tryParse(raw) ?? (throw BadSegment(name, raw, 'double'));
  }

  static bool asBool(GoRouterState s, String name) =>
      switch (asString(s, name)) {
        'true' => true,
        'false' => false,
        final raw => throw BadSegment(name, raw, 'bool'),
      };
}

/// Typed readers for query parameters, used by generated code.
///
/// Query parameters are optional by nature: a missing or unparsable value is
/// `null` (or left out of a list), never a not-found.
abstract final class Query {
  static String? asString(GoRouterState s, String name) =>
      s.uri.queryParameters[name];

  static int? asInt(GoRouterState s, String name) =>
      int.tryParse(asString(s, name) ?? '');

  static double? asDouble(GoRouterState s, String name) =>
      double.tryParse(asString(s, name) ?? '');

  static bool? asBool(GoRouterState s, String name) => _bool(asString(s, name));

  static List<String> asStringList(GoRouterState s, String name) =>
      s.uri.queryParametersAll[name] ?? const [];

  static List<int> asIntList(GoRouterState s, String name) =>
      [...asStringList(s, name).map(int.tryParse).nonNulls];

  static List<double> asDoubleList(GoRouterState s, String name) =>
      [...asStringList(s, name).map(double.tryParse).nonNulls];

  static List<bool> asBoolList(GoRouterState s, String name) =>
      [...asStringList(s, name).map(_bool).nonNulls];

  static bool? _bool(String? raw) => switch (raw) {
        'true' => true,
        'false' => false,
        _ => null,
      };
}

/// Appends a typed route's query parameters to its location. `null` values
/// and empty lists are left out.
String withQuery(String location, Map<String, Object?> query) {
  final q = <String, List<String>>{};
  for (final MapEntry(:key, :value) in query.entries) {
    final values = switch (value) {
      null => const <String>[],
      Iterable<Object?>() => [for (final v in value) '$v'],
      _ => ['$value'],
    };
    if (values.isNotEmpty) q[key] = values;
  }
  if (q.isEmpty) return location;
  return '$location?${Uri(queryParameters: q).query}';
}

/// Generated builders call this: parse the segments and query parameters, or
/// fall back to not-found when a segment doesn't fit its type
/// (`/products/abc`).
Widget buildWithParams<V>(
  V Function() parse,
  Widget Function(V params) build,
  Widget Function() notFound,
) {
  final V params;
  try {
    params = parse();
  } on BadSegment {
    return notFound();
  }
  return build(params);
}

/// Generated redirects call this: unparsable segments skip the guard and let
/// the builder show not-found.
FutureOr<String?> guardWithParams<V>(
  V Function() parse,
  GuardResult Function(V params) guard,
) {
  final V params;
  try {
    params = parse();
  } on BadSegment {
    return null;
  }
  return guard(params);
}
