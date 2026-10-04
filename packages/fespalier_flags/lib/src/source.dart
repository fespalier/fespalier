import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, immutable, kDebugMode;

/// Where flag values come from (since 0.9.0): a vendor SDK, fixed values, a fake.
///
/// Every read is synchronous and cheap, because guards and menus call it: answer from memory, never from the network,
/// a file or a platform channel. A read that throws is treated as `FeatureFlag.fallback` (and printed in debug).
abstract interface class FlagSource {
  /// The bool under [key], or [fallback] when there is none or it is not a bool.
  bool boolValue(String key, bool fallback);

  /// The string under [key], or [fallback].
  String stringValue(String key, String fallback);

  /// The int under [key], or [fallback].
  int intValue(String key, int fallback);

  /// The double under [key] (an int is widened), or [fallback].
  double doubleValue(String key, double fallback);

  /// An event each time values may have changed, sent once the new values can be read; null for a source whose
  /// values never change while the app runs.
  ///
  /// fespalier_flags listens with at most one subscription per ProviderContainer, opened when the first flag is
  /// watched and cancelled when the last watched flag is disposed. Listening must not start polling.
  Stream<FlagsChanged>? get changes;
}

/// Which flags a [FlagSource.changes] event is about (since 0.9.0).
@immutable
final class FlagsChanged {
  /// Only the flags under [keys] changed.
  const FlagsChanged(Set<String> this.keys);

  /// Any flag may have changed.
  const FlagsChanged.all() : keys = null;

  /// The keys that changed; null for all.
  final Set<String>? keys;

  /// Whether the flag under [key] has to be read again.
  bool affects(String key) => keys?.contains(key) ?? true;

  @override
  String toString() =>
      keys == null ? 'FlagsChanged.all()' : 'FlagsChanged($keys)';
}

/// Fixed values (since 0.9.0): `const ConstFlags({'labs': true})`, or `--dart-define`d ones
/// (`const ConstFlags({'labs': bool.fromEnvironment('LABS')})`). With no values, every flag is its fallback: what
/// `flagSource` is when the app does not override it.
///
/// A bool reads a `bool`, a string a `String`, an int an `int`, a double any `num`; anything else is the fallback.
final class ConstFlags implements FlagSource {
  /// A source that always answers [values].
  const ConstFlags([this.values = const <String, Object>{}]);

  /// The values, by key.
  final Map<String, Object> values;

  @override
  bool boolValue(String key, bool fallback) {
    final value = values[key];
    return value is bool ? value : fallback;
  }

  @override
  String stringValue(String key, String fallback) {
    final value = values[key];
    return value is String ? value : fallback;
  }

  @override
  int intValue(String key, int fallback) {
    final value = values[key];
    return value is int ? value : fallback;
  }

  @override
  double doubleValue(String key, double fallback) {
    final value = values[key];
    return value is num ? value.toDouble() : fallback;
  }

  /// Null: fixed values never change.
  @override
  Stream<FlagsChanged>? get changes => null;
}

/// A source that is not ready when the app starts (since 0.9.0): reads come from `meanwhile` until `source`
/// completes, then from what it completed with, and one `FlagsChanged.all()` is sent at the switch.
///
/// For a vendor whose start waits for the network (GrowthBook past its cache's TTL, LaunchDarkly on a first launch),
/// so that startup() does not wait for it and no timer bounds the wait. Until the switch every flag is
/// `meanwhile`'s answer, so a guard sends a cold deep link to a flagged route to its `orElse`. If `source` fails,
/// `meanwhile` stays (printed in debug).
final class AsyncFlags implements FlagSource {
  /// Reads [meanwhile] until [source] completes.
  AsyncFlags(
    Future<FlagSource> source, {
    FlagSource meanwhile = const ConstFlags(),
  }) : _current = meanwhile {
    // A callback on a Future: not a listener, not a timer.
    source.then<void>(_ready, onError: _failed);
  }

  FlagSource _current;
  bool _isReady = false;
  StreamSubscription<FlagsChanged>? _inner;
  late final StreamController<FlagsChanged> _controller =
      StreamController<FlagsChanged>.broadcast(
        sync: true,
        onListen: _attach,
        onCancel: _detach,
      );

  /// Whether `source` has completed with a source.
  bool get isReady => _isReady;

  @override
  bool boolValue(String key, bool fallback) =>
      _current.boolValue(key, fallback);

  @override
  String stringValue(String key, String fallback) =>
      _current.stringValue(key, fallback);

  @override
  int intValue(String key, int fallback) => _current.intValue(key, fallback);

  @override
  double doubleValue(String key, double fallback) =>
      _current.doubleValue(key, fallback);

  /// A broadcast stream: the current source's changes (while listened), and one `FlagsChanged.all()` at the switch.
  @override
  Stream<FlagsChanged> get changes => _controller.stream;

  void _attach() {
    final Stream<FlagsChanged>? changes;
    try {
      changes = _current.changes;
    } on Object catch (error, stackTrace) {
      _controller.addError(error, stackTrace);
      return;
    }
    _inner = changes?.listen(_controller.add, onError: _controller.addError);
  }

  void _detach() {
    final inner = _inner;
    _inner = null;
    inner?.cancel().ignore();
  }

  void _ready(FlagSource source) {
    _current = source;
    _isReady = true;
    if (_controller.hasListener) {
      _detach();
      _attach();
      _controller.add(const FlagsChanged.all());
    }
  }

  void _failed(Object error, StackTrace stackTrace) {
    reportFlags(
      "AsyncFlags' source failed, so the values meanwhile stay",
      error,
    );
  }
}

/// What fespalier_flags prints in debug when a source misbehaves, in fespalier's `dataCache` style
/// (`fespalier_flags: <what>: <error>`). Not exported.
void reportFlags(String what, Object error) {
  if (kDebugMode) debugPrint('fespalier_flags: $what: $error');
}
