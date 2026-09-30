import 'package:flutter/foundation.dart';

/// What an [ErrorView] receives: the error plus a way to try again.
@immutable
final class LoadFailure {
  const LoadFailure(this.error, this.stackTrace, {required this.retry});

  final Object error;
  final StackTrace stackTrace;

  /// Invalidates the route's data provider, which reruns `data.dart`.
  final VoidCallback retry;

  @override
  String toString() => 'LoadFailure($error)';
}
