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
  /// Creates the error for the segment [name] whose [value] isn't a [type].
  const BadSegment(this.name, this.value, this.type);

  /// The segment's name.
  final String name;

  /// The raw value from the URL, or `null` when the segment is missing.
  final String? value;

  /// The Dart type the segment should have been.
  final String type;

  @override
  String toString() => 'BadSegment: \$$name = "$value" is not a valid $type';
}

/// Typed readers for path segments, used by generated code.
abstract final class Segment {
  /// The segment [name] as a string; throws [BadSegment] when it is missing.
  static String asString(GoRouterState s, String name) =>
      s.pathParameters[name] ?? (throw BadSegment(name, null, 'String'));

  /// The segment [name] as an `int`; throws [BadSegment] when it isn't one.
  static int asInt(GoRouterState s, String name) {
    final raw = asString(s, name);
    return int.tryParse(raw) ?? (throw BadSegment(name, raw, 'int'));
  }

  /// The segment [name] as a `double`; throws [BadSegment] when it isn't one.
  static double asDouble(GoRouterState s, String name) {
    final raw = asString(s, name);
    return double.tryParse(raw) ?? (throw BadSegment(name, raw, 'double'));
  }

  /// The segment [name] as a `bool` (`true` or `false`); throws [BadSegment] otherwise.
  static bool asBool(GoRouterState s, String name) =>
      switch (asString(s, name)) {
        'true' => true,
        'false' => false,
        final raw => throw BadSegment(name, raw, 'bool'),
      };

  /// A segment that is an enum (`Category category`): the value of [values] (`Category.values`)
  /// whose `name` the segment spells, so `/shop/shoes` is `Category.shoes`. A segment that names
  /// no value is a [BadSegment], so the route shows not-found, as `/products/abc` does for an
  /// `int`. With [caseSensitive] false (the route's paths match in any case) `/shop/SHOES`
  /// is `Category.shoes` too; a name that matches exactly always wins.
  static T asEnum<T extends Enum>(
    GoRouterState s,
    String name,
    List<T> values, {
    bool caseSensitive = true,
  }) {
    final raw = asString(s, name);
    return _enumNamed(values, raw, caseSensitive: caseSensitive) ??
        (throw BadSegment(name, raw, '$T'));
  }

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

  /// A catch-all of numbers, booleans or dates (`List<int> rest`): [asRest], with each part
  /// read like one segment of that type. A part that doesn't parse is a [BadSegment], so the
  /// route shows not-found, as `/products/abc` does for an `int` segment.
  static List<int> asIntRest(GoRouterState s, String name) =>
      _rest(s, name, int.tryParse);

  /// The catch-all [name] as a list of `double`s; throws [BadSegment] when one isn't.
  static List<double> asDoubleRest(GoRouterState s, String name) =>
      _rest(s, name, double.tryParse);

  /// The catch-all [name] as a list of `num`s; throws [BadSegment] when one isn't.
  static List<num> asNumRest(GoRouterState s, String name) =>
      _rest(s, name, num.tryParse);

  /// The catch-all [name] as a list of `bool`s; throws [BadSegment] when one isn't.
  static List<bool> asBoolRest(GoRouterState s, String name) =>
      _rest(s, name, bool.tryParse);

  /// The catch-all [name] as a list of `DateTime`s; throws [BadSegment] when one isn't.
  static List<DateTime> asDateTimeRest(GoRouterState s, String name) =>
      _rest(s, name, DateTime.tryParse);

  /// A catch-all of enum values (`List<Category> path`): [asRest], with each part read by
  /// [asEnum]'s rules. A part that names no value is a [BadSegment] (not-found).
  static List<T> asEnumRest<T extends Enum>(
    GoRouterState s,
    String name,
    List<T> values, {
    bool caseSensitive = true,
  }) => _rest(
    s,
    name,
    (raw) => _enumNamed(values, raw, caseSensitive: caseSensitive),
  );

  static List<T> _rest<T>(
    GoRouterState s,
    String name,
    T? Function(String) parse,
  ) => [
    for (final raw in asRest(s, name))
      parse(raw) ?? (throw BadSegment(name, raw, '$T')),
  ];
}

/// Typed readers for query parameters, used by generated code.
///
/// Query parameters are optional by nature: a missing or unparsable value is
/// `null` (or left out of a list), never a not-found.
abstract final class Query {
  /// The query parameter [name], or `null` when it is absent.
  static String? asString(GoRouterState s, String name) =>
      s.uri.queryParameters[name];

  /// The query parameter [name] as an `int`, or `null` when it is absent or not one.
  static int? asInt(GoRouterState s, String name) =>
      int.tryParse(asString(s, name) ?? '');

  /// The query parameter [name] as a `double`, or `null` when it is absent or not one.
  static double? asDouble(GoRouterState s, String name) =>
      double.tryParse(asString(s, name) ?? '');

  /// The query parameter [name] as a `bool`, or `null` when it is absent or not one.
  static bool? asBool(GoRouterState s, String name) => _bool(asString(s, name));

  /// Every value of the query parameter [name], in order; empty when it is absent.
  static List<String> asStringList(GoRouterState s, String name) =>
      s.uri.queryParametersAll[name] ?? const [];

  /// Every value of [name] that is an `int`; the others are left out.
  static List<int> asIntList(GoRouterState s, String name) => [
    ...asStringList(s, name).map(int.tryParse).nonNulls,
  ];

  /// Every value of [name] that is a `double`; the others are left out.
  static List<double> asDoubleList(GoRouterState s, String name) => [
    ...asStringList(s, name).map(double.tryParse).nonNulls,
  ];

  /// Every value of [name] that is a `bool`; the others are left out.
  static List<bool> asBoolList(GoRouterState s, String name) => [
    ...asStringList(s, name).map(_bool).nonNulls,
  ];

  /// A query parameter that is an enum (`Sort? sort`): the value of [values] whose `name` it
  /// spells, or `null` when it is missing or names none. [caseSensitive] is as for
  /// [Segment.asEnum].
  static T? asEnum<T extends Enum>(
    GoRouterState s,
    String name,
    List<T> values, {
    bool caseSensitive = true,
  }) => _enumNamed(values, asString(s, name), caseSensitive: caseSensitive);

  /// Every `?name=` value that names a value of [values], in order; the others are left out.
  static List<T> asEnumList<T extends Enum>(
    GoRouterState s,
    String name,
    List<T> values, {
    bool caseSensitive = true,
  }) => [
    ...asStringList(s, name)
        .map((raw) => _enumNamed(values, raw, caseSensitive: caseSensitive))
        .nonNulls,
  ];

  static bool? _bool(String? raw) => switch (raw) {
    'true' => true,
    'false' => false,
    _ => null,
  };
}

/// The value of [values] whose `name` is [raw], or `null` when there is none. An exact match
/// wins; with [caseSensitive] false the names are compared without regard to case as well
/// (an enum with `a` and `A` still tells them apart).
T? _enumNamed<T extends Enum>(
  Iterable<T> values,
  String? raw, {
  bool caseSensitive = true,
}) {
  if (raw == null) return null;
  for (final v in values) {
    if (v.name == raw) return v;
  }
  if (caseSensitive) return null;
  final lower = raw.toLowerCase();
  for (final v in values) {
    if (v.name.toLowerCase() == lower) return v;
  }
  return null;
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
/// and empty lists are left out. An enum is written as its `name`, which
/// [Query.asEnum] reads back.
String withQuery(String location, Map<String, Object?> query) {
  final q = <String, List<String>>{};
  for (final MapEntry(:key, :value) in query.entries) {
    final values = switch (value) {
      null => const <String>[],
      Iterable<Object?>() => [for (final v in value) _queryPart(v)],
      _ => [_queryPart(value)],
    };
    if (values.isNotEmpty) q[key] = values;
  }
  if (q.isEmpty) return location;
  return '$location?${Uri(queryParameters: q).query}';
}

String _queryPart(Object? value) => value is Enum ? value.name : '$value';

/// The path of a catch-all's parts, each encoded: `/a/b%20c`, or nothing for none.
/// A typed route appends it to its location. The parts are strings, numbers,
/// booleans, dates (a `DateTime` is written as ISO 8601) or enums (written as their
/// `name`); [Segment.asRest] and its typed siblings read them back.
String restPath(Iterable<Object> rest) =>
    [for (final part in rest) '/${_restPart(part)}'].join();

/// A catch-all's parts as one string, for keying a provider (lists compare by
/// identity, strings by value). [restParts] takes it apart again.
String restKey(Iterable<Object> rest) =>
    [for (final part in rest) _restPart(part)].join('/');

String _restPart(Object part) => Uri.encodeComponent(switch (part) {
  DateTime() => part.toIso8601String(),
  Enum() => part.name,
  _ => '$part',
});

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
