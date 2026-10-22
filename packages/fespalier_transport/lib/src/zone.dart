import 'dart:async';

/// An abort trigger that travels in a [Zone] (since 0.21.0), for code that cannot hand one to the
/// request it makes: a generated client takes no abort trigger, so the provider that calls it runs
/// the call in a zone that carries one (`ref.cancellable` in `fespalier_cratestack`), and the
/// transport adapter (`TransportAdapter` in `fespalier_dio`) merges it into the request's
/// `abortTrigger`. The key lives here so that neither has to depend on the other.
///
/// ```dart
/// final orders = TransportZone.run(trigger, () => client.orders());
/// ```
abstract final class TransportZone {
  /// The zone key whose value is a `Future<void>` that completes to abort the sends made inside.
  static const Symbol abortTrigger = #fespalierTransportAbortTrigger;

  /// Runs [body] in a zone where [trigger] is the current abort trigger, and returns what [body]
  /// returns. Starts no timer. A trigger set inside [body] replaces this one for its own sends.
  static R run<R>(Future<void> trigger, R Function() body) =>
      runZoned<R>(body, zoneValues: <Object?, Object?>{abortTrigger: trigger});

  /// The abort trigger of the current zone, or null when none was set.
  static Future<void>? current() {
    final value = Zone.current[abortTrigger];
    return value is Future<void> ? value : null;
  }

  /// [a] and [b] as one trigger that completes when either does; the other when only one is
  /// given; null when neither is. Starts no timer.
  static Future<void>? merge(Future<void>? a, Future<void>? b) {
    if (a == null) return b;
    if (b == null) return a;
    return Future.any<void>(<Future<void>>[a, b]);
  }
}
