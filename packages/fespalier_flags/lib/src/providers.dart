import 'package:fespalier/fespalier.dart';

import 'flag.dart';
import 'source.dart';

/// Where every flag is read from (since 0.9.0). Override it in startup.dart's startup():
/// `flagSource.overrideWithValue(source)`; in a test, `flagSource.overrideWithValue(FakeFlags({...}))`.
/// Without an override every flag is its fallback (`const ConstFlags()`).
final flagSource = Provider<FlagSource>(
  (ref) => const ConstFlags(),
  name: 'flagSource',
);

/// The flag [f] for a guard, a widget or a provider to watch (since 0.9.0): `ref.watch(flag(checkoutV2))`.
///
/// The value is there at once (never loading, never a Future). Watching it re-runs the watcher when the value
/// changes, and only then. Each flag is an autoDispose provider: what nothing watches is not read or listened to.
ProviderListenable<T> flag<T extends Object>(FeatureFlag<T> f) =>
    switch (f) {
          final BoolFlag b => _boolFlags(b),
          final StringFlag s => _stringFlags(s),
          final IntFlag i => _intFlags(i),
          final DoubleFlag d => _doubleFlags(d),
        }
        as ProviderListenable<T>;

/// The one subscription to flagSource.changes in a container, while a flag is watched. Its state carries a
/// sequence number so that two equal events still notify.
final _flagEvents =
    NotifierProvider.autoDispose<_FlagEvents, (int, FlagsChanged)?>(
      _FlagEvents.new,
    );

const _changesFailed = "the flag source's changes reported an error";

final class _FlagEvents extends Notifier<(int, FlagsChanged)?> {
  @override
  (int, FlagsChanged)? build() {
    final Stream<FlagsChanged>? changes;
    try {
      changes = ref.watch(flagSource).changes;
    } on Object catch (error) {
      reportFlags(_changesFailed, error); // F2
      return null;
    }
    if (changes == null) return null;
    // An event replayed during listen() is not a change: build reads the current values anyway.
    var built = false;
    var seq = 0;
    final sub = changes.listen(
      (event) {
        if (built) state = (++seq, event);
      },
      onError: (Object error, StackTrace _) =>
          reportFlags(_changesFailed, error), // F2
    );
    ref.onDispose(sub.cancel);
    built = true;
    return null;
  }
}

final class _FlagNotifier<T extends Object> extends Notifier<T> {
  _FlagNotifier(this._flag);

  final FeatureFlag<T> _flag;

  @override
  T build() {
    final source = ref.watch(flagSource);
    ref.listen(_flagEvents, (_, next) {
      if (next != null && next.$2.affects(_flag.key)) state = _read(source);
    });
    return _read(source);
  }

  /// The source's answer, or the fallback when it throws (F1).
  T _read(FlagSource source) {
    final f = _flag;
    try {
      final Object value = switch (f) {
        final BoolFlag b => source.boolValue(b.key, b.fallback),
        final StringFlag s => source.stringValue(s.key, s.fallback),
        final IntFlag i => source.intValue(i.key, i.fallback),
        final DoubleFlag d => source.doubleValue(d.key, d.fallback),
      };
      return value as T;
    } on Object catch (error) {
      reportFlags(
        'reading ${f.key} threw, so its fallback (${f.fallback}) is used',
        error,
      ); // F1
      return f.fallback;
    }
  }
}

final _boolFlags = NotifierProvider.autoDispose
    .family<_FlagNotifier<bool>, bool, BoolFlag>(
      _FlagNotifier<bool>.new,
      name: 'flag',
    );

final _stringFlags = NotifierProvider.autoDispose
    .family<_FlagNotifier<String>, String, StringFlag>(
      _FlagNotifier<String>.new,
      name: 'flag',
    );

final _intFlags = NotifierProvider.autoDispose
    .family<_FlagNotifier<int>, int, IntFlag>(
      _FlagNotifier<int>.new,
      name: 'flag',
    );

final _doubleFlags = NotifierProvider.autoDispose
    .family<_FlagNotifier<double>, double, DoubleFlag>(
      _FlagNotifier<double>.new,
      name: 'flag',
    );
