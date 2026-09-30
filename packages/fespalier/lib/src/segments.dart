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

/// Generated builders call this: parse the segments, or fall back to
/// not-found when one doesn't fit its type (`/products/abc`).
Widget buildWithSegments<V>(
  V Function() parse,
  Widget Function(V segments) build,
  Widget Function() notFound,
) {
  final V segments;
  try {
    segments = parse();
  } on BadSegment {
    return notFound();
  }
  return build(segments);
}

/// Generated redirects call this: unparsable segments skip the guard and let
/// the builder show not-found.
FutureOr<String?> guardWithSegments<V>(
  V Function() parse,
  GuardResult Function(V segments) guard,
) {
  final V segments;
  try {
    segments = parse();
  } on BadSegment {
    return null;
  }
  return guard(segments);
}
