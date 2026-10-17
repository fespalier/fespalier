import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';

import 'idle.dart';
import 'policy.dart';
import 'prompt.dart';
import 'telemetry.dart';

/// Whether the app is unlocked (since 0.13.0).
sealed class UnlockState {
  const UnlockState();
}

/// Nothing was proved since the app started, since [BiometricUnlock.lock], or since the policy gave
/// the unlock back.
final class Locked extends UnlockState {
  /// The locked state.
  const Locked();
}

/// A prompt is up.
final class Unlocking extends UnlockState {
  /// [wasUnlocked] says the app was unlocked before this prompt (a [withBiometrics] on an open
  /// page): a guard keeps its answer meanwhile, and a prompt that fails goes back to [Unlocked].
  const Unlocking({this.wasUnlocked = false});

  /// Whether the app was unlocked when this prompt started.
  final bool wasUnlocked;
}

/// The person proved who they are at [at] (read from `package:clock`).
final class Unlocked extends UnlockState {
  /// Unlocked at [at].
  const Unlocked(this.at);

  /// When the last prompt succeeded.
  final DateTime at;
}

/// The unlock state and the only thing that prompts (since 0.13.0).
final biometricUnlock = NotifierProvider<BiometricUnlock, UnlockState>(
  BiometricUnlock.new,
);

/// Where the unlock state lives.
///
/// It relocks when the app comes back from being hidden (core's `appShowSignal`: the app was in the
/// background or minimised, not just inactive for a notification shade or the Face ID sheet) at least
/// `BiometricPolicy.resumeGrace` after the unlock: `build` watches the signal, so it runs again, and it
/// starts no timer and adds no listener of its own. An unlock does not expire by itself: a `maxAge`
/// is checked when a guard runs or [isFresh] is asked, that is at the next navigation or return.
///
/// A clock set back (a negative age) counts as expired everywhere, so winding the clock back does not
/// keep an unlock alive.
class BiometricUnlock extends Notifier<UnlockState> {
  Future<BiometricOutcome>? _flight;
  DateTime? _at;
  DateTime? _activityAt;
  Unlocked? _unlocked;
  int _shows = 0;
  int? _ticks;
  // The policy's idleTimeout as `build` last saw it, so a touch or a hover never reads a provider.
  Duration? _idleTimeout;

  @override
  UnlockState build() {
    final shows = ref.watch(appShowSignal);
    final policy = ref.watch(biometricPolicy);
    final grace = policy.resumeGrace;
    _idleTimeout = policy.idleTimeout;
    assert(
      _idleTimeout == null || _idleTimeout! > Duration.zero,
      'fespalier_biometrics: BiometricPolicy.idleTimeout must be positive; zero would absorb and lock on every touch',
    );
    final ticks = ref.watch(biometricIdleTicker);
    // Only a return from hidden applies the grace: a policy change rebuilds this too, and must not relock.
    if (shows != _shows) {
      _shows = shows;
      final at = _at;
      if (at != null && _expired(at, grace)) _at = null;
    }
    // A tick of the app's ticker is the only thing here that ends an idle unlock; the first one is
    // the provider's own start, and a policy change rebuilds this too, which is not a tick.
    if (ticks != _ticks) {
      final first = _ticks == null;
      _ticks = ticks;
      if (!first && _at != null && isIdle()) _at = null;
    }
    final at = _at;
    // A show during a prompt (the platform's sheet can background the app) keeps the prompt, and
    // the relock that was due is not lost: the state under the prompt is whatever `_at` is now.
    if (_flight != null) return Unlocking(wasUnlocked: at != null);
    return _stateOf(at);
  }

  /// The unlocked state for [at], the same object while it is the same unlock: a tick that keeps the
  /// unlock tells no listener.
  UnlockState _stateOf(DateTime? at) {
    if (at == null) return const Locked();
    final known = _unlocked;
    if (known != null && known.at == at) return known;
    return _unlocked = Unlocked(at);
  }

  /// Whether [at] is [limit] old or older by `clock.now()`; a negative age (the clock was set back) is expired.
  static bool _expired(DateTime at, Duration limit) {
    final age = clock.now().difference(at);
    return age.isNegative || age >= limit;
  }

  /// Asks the platform to check, and returns how it ended.
  ///
  /// Single-flight: while a prompt is up, a second call gets the same `Future`, so two buttons, a
  /// double tap or a guard that runs again never stack two sheets. A success is [Unlocked]; anything
  /// else leaves the state as it is now (a [lock] or a relock that happened under the sheet is kept).
  /// [reason] is what the person reads. It throws only when `biometricPrompt` was never overridden;
  /// a prompt that throws is [BiometricOutcome.failed].
  Future<BiometricOutcome> unlock(String reason) {
    final running = _flight;
    if (running != null) return running;
    final prompt = ref.read(biometricPrompt);
    state = Unlocking(wasUnlocked: _at != null);
    return _flight = _run(prompt, reason);
  }

  Future<BiometricOutcome> _run(BiometricPrompt prompt, String reason) async {
    final span = promptSpan();
    var outcome = BiometricOutcome.failed;
    try {
      // `await` always yields, even on a prompt that throws at once, so `unlock` has set `_flight`
      // before the line that clears it runs.
      outcome = await Future.sync(() => prompt.authenticate(reason));
      promptSpanEnd(span, outcome);
    } catch (error, stackTrace) {
      promptSpanEnd(span, outcome, error: error, stackTrace: stackTrace);
    }
    _flight = null;
    if (!ref.mounted) return outcome;
    if (outcome == BiometricOutcome.success) {
      final at = _at = clock.now();
      _activityAt = null;
      state = _stateOf(at);
    } else {
      state = _stateOf(_at);
    }
    return outcome;
  }

  /// Gives the unlock back now (a "Lock" button, a sign-out). A prompt already up still ends, and
  /// a success then unlocks again.
  void lock() {
    _at = null;
    _activityAt = null;
    state = _flight == null ? const Locked() : const Unlocking();
  }

  /// Whether the app is unlocked and the unlock is younger than [maxAge] by `clock.now()`
  /// (without [maxAge], whether it is unlocked at all). Under a prompt that started over an unlock
  /// it answers for that unlock, so a guard that runs again during a [withBiometrics] sheet keeps its answer.
  bool isFresh({Duration? maxAge}) {
    final at = _at;
    if (at == null || isIdle()) return false;
    return maxAge == null || !_expired(at, maxAge);
  }

  /// Records activity now, by `clock.now()` (since 0.19.0); `BiometricActivity` calls it on every touch and
  /// key. It writes a field and not state, so a touch rebuilds nothing. It does nothing while locked,
  /// without an `idleTimeout`, or once the idle limit has passed: a late touch does not bring an
  /// expired unlock back.
  void touch() {
    if (_at == null || _idleTimeout == null || isIdle()) return;
    _activityAt = clock.now();
  }

  /// Whether the app is unlocked, the policy has an `idleTimeout`, and the time since the later of the
  /// unlock and the last [touch] is at least that long by `clock.now()` (since 0.19.0). A negative
  /// age (the clock was set back) is idle. Under a prompt that started over an unlock it answers for
  /// that unlock.
  bool isIdle() {
    final at = _at;
    final limit = _idleTimeout;
    if (at == null || limit == null) return false;
    final activity = _activityAt;
    final last = activity != null && activity.isAfter(at) ? activity : at;
    return _expired(last, limit);
  }
}

/// The policy for relocking (since 0.13.0); the default relocks on a return from the background 10 seconds or more after the unlock.
final biometricPolicy = Provider<BiometricPolicy>(
  (ref) => const BiometricPolicy(),
);
