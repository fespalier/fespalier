import 'dart:async';
import 'dart:collection';

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

  /// A catch-all segment (`$$rest`): every remaining part of the path, each
  /// decoded on its own, so `/docs/a%2Fb/c` is `['a/b', 'c']`. Empty when the
  /// route matched without the segment (an optional catch-all, `$$$rest`).
  ///
  /// go_router hands the parameter over as one decoded string, in which an
  /// encoded slash can't be told from a real one; the parts are read from the
  /// requested location instead, counting the segments before the catch-all in
  /// the route's full path.
  static List<String> asRest(GoRouterState s, String name) {
    final raw = s.pathParameters[name];
    if (raw == null || raw.isEmpty) return const [];
    final own = s.fullPath?.split('/').where((p) => p.isNotEmpty).toList();
    if (own != null && own.isNotEmpty && own.last.startsWith(':$name')) {
      final all = s.uri.pathSegments;
      if (own.length - 1 <= all.length) {
        return [
          for (final part in all.skip(own.length - 1))
            if (part.isNotEmpty) part,
        ];
      }
    }
    return [
      for (final part in raw.split('/'))
        if (part.isNotEmpty) part,
    ];
  }
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

/// A list with value equality, so a `List` query parameter can key a provider
/// family: two lists with the same elements are the same key. Generated code
/// wraps `data.dart`'s `List<T>` parameters in one; `data()` still gets a plain
/// `List<T>` (this is one, and it can't be changed).
final class QueryList<T> extends UnmodifiableListView<T> {
  /// Copies [items], so changing the source list later doesn't change the key.
  QueryList(Iterable<T> items) : super(List<T>.of(items));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! QueryList<Object?> || other.length != length) return false;
    for (var i = 0; i < length; i++) {
      if (this[i] != other[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(this);
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

/// The path of a catch-all's parts, each encoded: `/a/b%20c`, or nothing for none.
/// A typed route appends it to its location.
String restPath(Iterable<String> rest) =>
    [for (final part in rest) '/${Uri.encodeComponent(part)}'].join();

/// A catch-all's parts as one string, for keying a provider (lists compare by
/// identity, strings by value). [restParts] takes it apart again.
String restKey(Iterable<String> rest) =>
    [for (final part in rest) Uri.encodeComponent(part)].join('/');

/// The parts [restKey] joined.
List<String> restParts(String key) => [
  for (final part in key.split('/'))
    if (part.isNotEmpty) Uri.decodeComponent(part),
];

/// A page's `extra` parameter: what `context.go(location, extra: ...)` passed,
/// or `null` when it passed nothing or the page was opened by URL (a deep link,
/// a reload). `T` is the parameter's type, inferred at the call in the
/// generated code. In debug builds an object of another type is an error; in
/// release builds it reads as `null`.
T? extraOf<T>(GoRouterState s) {
  final extra = s.extra;
  if (extra is T) return extra;
  assert(
    extra == null,
    'this page takes an extra of type $T, but was navigated to with a '
    '${extra.runtimeType}',
  );
  return null;
}

/// A layout's, guard's or redirect's `extra` parameter: what the navigation to
/// the location it is at passed, like [extraOf], but it never asserts. These see
/// the extra of every route they cover, including routes that take another
/// type or none, so an object that isn't a `T` is just `null` to them.
T? extraOrNull<T>(GoRouterState s) {
  final extra = s.extra;
  return extra is T ? extra : null;
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
