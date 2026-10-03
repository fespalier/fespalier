import 'dart:async';

/// Applies [next] to [value] without making a `Future` of a plain value: synchronous while
/// [value] is.
FutureOr<R> then<T, R>(FutureOr<T> value, FutureOr<R> Function(T value) next) =>
    value is Future<T> ? value.then<R>(next) : next(value);

/// Every provider here is built from state the app owns: a failing one is not tried again (a
/// retry would start a timer).
Duration? noRetry(int retryCount, Object error) => null;
