import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// When the value a `data.dart` loaded is old enough to load again (since 0.8.0).
///
/// Declared as `const freshness = Freshness(...)` in a data.dart (that data) or a
/// route.dart (every data() function at and below that folder; the nearest wins, and a
/// data.dart's own wins over all of them).
///
/// A value is stale once it has been in memory for [staleTime] since it arrived. A stale
/// value is loaded again the next time something reads it, and shown meanwhile. It is
/// never polled: nothing in here starts a timer.
final class Freshness {
  /// Creates the rules a data.dart's value is loaded again by.
  const Freshness({
    this.staleTime,
    this.refetchOnResume = false,
    this.refetchOnReconnect = false,
  });

  /// How long a value counts as fresh after it arrived. Once it is older, the next
  /// read (a page opening on it, a prefetch, a page shown again) shows it and loads
  /// it again. Null: never by age (what a route without `freshness` does).
  final Duration? staleTime;

  /// Load again when the app comes back to the foreground, if the value is at
  /// least [staleTime] old (or always, with no [staleTime]).
  final bool refetchOnResume;

  /// Load again when [reconnectSignal] fires, under the same rule.
  final bool refetchOnReconnect;
}

/// A count that goes up each time data should check its age ([fire]). Since 0.8.0.
///
/// What [appResumeSignal] and [reconnectSignal] are made of. A data provider with
/// `refetchOnResume` or `refetchOnReconnect` listens to the signal and, when it changes,
/// loads again if its value is old enough.
class RefetchSignal extends Notifier<int> {
  @override
  int build() => 0;

  /// Every data provider that listens loads again if it is old enough.
  void fire() => state++;
}

/// A [RefetchSignal] that fires on `AppLifecycleListener.onResume` (since 0.8.0).
///
/// It is created only while a provider with `refetchOnResume` listens to it, and its
/// listener is disposed with it. It needs a `WidgetsBinding`: a test of such a provider
/// without one overrides [appResumeSignal] with `appResumeSignal.overrideWith(RefetchSignal.new)`.
class AppResumeSignal extends RefetchSignal {
  @override
  int build() {
    final listener = AppLifecycleListener(onResume: fire);
    ref.onDispose(listener.dispose);
    return 0;
  }
}

/// What `Freshness(refetchOnResume: true)` listens to (since 0.8.0).
final appResumeSignal = NotifierProvider.autoDispose<RefetchSignal, int>(
  AppResumeSignal.new,
);

/// What `Freshness(refetchOnReconnect: true)` listens to (since 0.8.0).
///
/// Flutter has no API for "the network is back", so this never fires by itself: override
/// it with a [RefetchSignal] whose `build` listens to your connectivity source, or call
/// `ref.read(reconnectSignal.notifier).fire()`.
final reconnectSignal = NotifierProvider.autoDispose<RefetchSignal, int>(
  RefetchSignal.new,
);

/// What a provider remembers about its value: when it arrived, and whether a reload
/// is already on its way.
final class _Stamp {
  /// When the value arrived; null while loading or after an error.
  DateTime? at;

  /// A reload has been decided, so a second reason in the same instant adds nothing.
  bool scheduled = false;
}

/// What the generated provider of a data.dart with a [Freshness] wraps its value in
/// (since 0.8.0).
///
/// It returns [value] itself (a `Future` stays the `Future`, a value stays a value, a
/// `Stream` stays the `Stream`), and registers on [ref] the checks [freshness] asks for.
/// Call it in a provider of your own (a selector's target, a provider-form data.dart) to
/// give it the same rules:
/// `Future<Product> build() => freshData(ref, const Freshness(...), _fetch());`
///
/// It starts no timer. A stream is never stale, so for one it does nothing by age.
T freshData<T>(Ref ref, Freshness freshness, T value) {
  final stamp = _Stamp();
  if (value is Future<Object?>) {
    // A side `then`, like traceData's: the returned object is untouched.
    value.then<void>(
      (_) => stamp.at = clock.now(),
      onError: (Object _, StackTrace _) {},
    );
  } else if (value is! Stream<Object?>) {
    // After the listener that created the provider has been added, so that one
    // isn't a "read" of a value that arrived in the same instant.
    scheduleMicrotask(() => stamp.at ??= clock.now());
  }
  bool older(Duration age) {
    final at = stamp.at;
    return at != null && !stamp.scheduled && clock.now().difference(at) >= age;
  }

  final staleTime = freshness.staleTime;
  if (staleTime != null) {
    // A life-cycle can't use `ref` (Riverpod asserts): decide here, invalidate in a
    // microtask, which is not a timer and runs before the next frame.
    void onRead() {
      if (!older(staleTime)) return;
      stamp.scheduled = true;
      scheduleMicrotask(() {
        if (ref.mounted) ref.invalidateSelf();
      });
    }

    ref.onAddListener(onRead);
    ref.onResume(onRead);
  }
  void onSignal(int? _, int _) {
    if (!older(staleTime ?? Duration.zero)) return;
    stamp.scheduled = true;
    ref.invalidateSelf();
  }

  if (freshness.refetchOnResume) ref.listen(appResumeSignal, onSignal);
  if (freshness.refetchOnReconnect) ref.listen(reconnectSignal, onSignal);
  return value;
}
