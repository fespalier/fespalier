import 'package:fespalier/fespalier.dart';

/// One line of an [InvalidationTable]: which events, and what they make stale (since 0.13.0).
final class InvalidationRule<E> {
  /// Creates a rule: when [matches] accepts an event, [targets] are the providers (or families) to
  /// invalidate for it.
  const InvalidationRule(this.matches, this.targets);

  /// A rule for events of one type, `InvalidationRule.on<OrderChanged, CoreEvent>((e) => [orderProvider(e.id)])`.
  static InvalidationRule<E> on<T extends E, E>(
    List<ProviderOrFamily> Function(T event) targets,
  ) => InvalidationRule<E>(
    (event) => event is T,
    (event) => targets(event as T),
  );

  /// Whether the event concerns this rule.
  final bool Function(E event) matches;

  /// What the event makes stale. A family invalidates all its members, a provider call only that one.
  final List<ProviderOrFamily> Function(E event) targets;
}

/// A pure table from a core's events to the providers they make stale (since 0.13.0).
///
/// The push form of [ChangeFeed], for an app that owns its subscription (or that does not want to
/// edit its `data.dart` files to watch a topic): the table holds no container, no `Ref`, no stream.
/// The app calls [apply] for each event, from wherever it already receives them, with the
/// invalidation function of the container it has (`container.invalidate`, or a `ref.invalidate`
/// in a provider that listens to [ChangeFeed.latest]).
///
/// ```dart
/// final table = InvalidationTable<CoreEvent>([
///   InvalidationRule.on<OrderChanged, CoreEvent>((e) => [orderProvider(e.id), ordersProvider]),
///   InvalidationRule.on<CartCleared, CoreEvent>((_) => [cartProvider]),
/// ]);
/// // in the app's own subscription:
/// table.apply(event, container.invalidate);
/// ```
final class InvalidationTable<E> {
  /// Creates a table of [rules], applied in order.
  const InvalidationTable(this.rules);

  /// The rules, in order.
  final List<InvalidationRule<E>> rules;

  /// Invalidates, through [invalidate], what [event] makes stale: every target of every matching
  /// rule, once each. Returns how many providers were invalidated.
  int apply(E event, void Function(ProviderOrFamily provider) invalidate) {
    final seen = <ProviderOrFamily>{};
    for (final rule in rules) {
      if (!rule.matches(event)) continue;
      for (final target in rule.targets(event)) {
        if (seen.add(target)) invalidate(target);
      }
    }
    return seen.length;
  }
}
