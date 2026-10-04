/// What tests use from fespalier_flags (since 0.9.0).
library;

import 'dart:async';

import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;

export 'package:fespalier_flags/fespalier_flags.dart'
    show FlagSource, FlagsChanged;

/// A FlagSource for tests: values in memory, changed with [set], each change delivered synchronously (since 0.9.0).
///
/// `flagSource.overrideWithValue(FakeFlags({'labs': true}))` in `pumpRouter`'s overrides or in
/// test/routes/setup.dart's `overrides(pattern)`. Call [set] from the test body, not while a widget builds.
final class FakeFlags implements FlagSource {
  /// Flags with [values]; a key it lacks, or a value of another type, is the flag's fallback.
  FakeFlags([Map<String, Object> values = const {}])
    : _strict = false,
      _values = {...values};

  /// Like [FakeFlags.new], but a key it lacks or a value of another type throws a StateError: a typo in a
  /// key fails the test instead of reading the fallback.
  ///
  /// The error is also reported to `FlutterError.reportError`, because fespalier_flags treats a read that throws as
  /// the flag's fallback (a guard must never throw because of a flag): the report is what fails a `testWidgets`.
  FakeFlags.strict(Map<String, Object> values)
    : _strict = true,
      _values = {...values};

  final bool _strict;
  final Map<String, Object> _values;
  final _changes = StreamController<FlagsChanged>.broadcast(sync: true);
  var _listeners = 0;

  /// The values now.
  Map<String, Object> get values => Map.unmodifiable(_values);

  /// Sets [key] to [value] (null removes it) and sends `FlagsChanged({key})`.
  void set(String key, Object? value) {
    _apply(key, value);
    _changes.add(FlagsChanged({key}));
  }

  /// Sets every entry of [values] (null removes) and sends one `FlagsChanged(values.keys.toSet())`.
  void setAll(Map<String, Object?> values) {
    values.forEach(_apply);
    _changes.add(FlagsChanged(values.keys.toSet()));
  }

  void _apply(String key, Object? value) {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  /// How many listen to [changes] now: 0 once nothing watches a flag.
  int get listenerCount => _listeners;

  /// The value under [key] when it is a [T] (an int is widened for a double); the fallback otherwise, or a
  /// StateError for a strict fake.
  T _read<T extends Object>(
    String key,
    T fallback,
    String type,
    T? Function(Object value) convert,
  ) {
    final value = _values[key];
    if (value == null) {
      if (!_strict) return fallback;
      throw _report(StateError('FakeFlags has no value for "$key"'));
    }
    final converted = convert(value);
    if (converted != null) return converted;
    if (!_strict) return fallback;
    throw _report(
      StateError(
        'FakeFlags has "$key" = $value (${value.runtimeType}), which is not a $type',
      ),
    );
  }

  StateError _report(StateError error) {
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, library: 'fespalier_flags'),
    );
    return error;
  }

  @override
  bool boolValue(String key, bool fallback) =>
      _read(key, fallback, 'bool', (v) => v is bool ? v : null);

  @override
  String stringValue(String key, String fallback) =>
      _read(key, fallback, 'String', (v) => v is String ? v : null);

  @override
  int intValue(String key, int fallback) =>
      _read(key, fallback, 'int', (v) => v is int ? v : null);

  @override
  double doubleValue(String key, double fallback) =>
      _read(key, fallback, 'double', (v) => v is num ? v.toDouble() : null);

  /// A broadcast stream whose events are delivered synchronously by [set] and [setAll].
  @override
  Stream<FlagsChanged> get changes => Stream<FlagsChanged>.multi((listener) {
    _listeners++;
    final sub = _changes.stream.listen(listener.addSync);
    listener.onCancel = () {
      _listeners--;
      return sub.cancel();
    };
  }, isBroadcast: true);
}
