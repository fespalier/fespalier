import 'dart:async';

/// Runs [next] on [value] without making it async when [value] is not: what keeps a read from a
/// store that answers synchronously synchronous (no `Future`, no microtask).
FutureOr<R> andThen<T, R>(
  FutureOr<T> value,
  FutureOr<R> Function(T value) next,
) {
  if (value is Future<T>) return value.then(next);
  return next(value);
}

/// The results of [values] in order, as a `Future` only if one of them is.
FutureOr<List<T>> allOf<T>(Iterable<FutureOr<T>> values) {
  final list = values.toList();
  if (list.any((v) => v is Future<T>)) {
    return Future.wait<T>([for (final v in list) Future<T>.value(v)]);
  }
  return [for (final v in list) v as T];
}
