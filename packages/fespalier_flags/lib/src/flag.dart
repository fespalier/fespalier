import 'package:flutter/foundation.dart' show immutable;

/// A feature flag: its key at the source and the value used when the source has none (since 0.9.0).
///
/// Declare each one once, `const`, and read it with `ref.watch(flag(f))`. Two declarations with the same type, key
/// and fallback are the same flag.
@immutable
sealed class FeatureFlag<T extends Object> {
  /// A flag read under [key].
  const FeatureFlag(this.key, {required this.fallback});

  /// The flag's key at the source (`'checkout_v2'`).
  final String key;

  /// The value while the source has none for [key], has one of another type, or fails to answer.
  final T fallback;

  @override
  bool operator ==(Object other) =>
      other is FeatureFlag<Object> &&
      other.runtimeType == runtimeType &&
      other.key == key &&
      other.fallback == fallback;

  @override
  int get hashCode => Object.hash(runtimeType, key, fallback);

  @override
  String toString() => '$runtimeType($key, fallback: $fallback)';
}

/// An on/off flag; off ([fallback] `false`) unless the source says otherwise.
final class BoolFlag extends FeatureFlag<bool> {
  /// A flag that is [fallback] (false by default) until the source has a bool for [key].
  const BoolFlag(super.key, {super.fallback = false});
}

/// A flag with a string value: a variant, a layout name.
final class StringFlag extends FeatureFlag<String> {
  /// A string flag read under [key].
  const StringFlag(super.key, {required super.fallback});
}

/// A flag with a whole-number value: a limit, a minimum build.
final class IntFlag extends FeatureFlag<int> {
  /// An int flag read under [key].
  const IntFlag(super.key, {required super.fallback});
}

/// A flag with a decimal value: a threshold, a rate. An int at the source is read as a double.
final class DoubleFlag extends FeatureFlag<double> {
  /// A double flag read under [key].
  const DoubleFlag(super.key, {required super.fallback});
}
