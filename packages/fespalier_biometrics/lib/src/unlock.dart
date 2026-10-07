import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';

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
  int _shows = 0;

  @override
  UnlockState build() {
    final shows = ref.watch(appShowSignal);
    final grace = ref.watch(biometricPolicy).resumeGrace;
    // Only a return from hidden applies the grace: a policy change rebuilds this too, and must not relock.
    if (shows != _shows) {
      _shows = shows;
      final at = _at;
      if (at != null && _expired(at, grace)) _at = null;
    }
    final at = _at;
    // A show during a prompt (the platform's sheet can background the app) keeps the prompt, and
    // the relock that was due is not lost: the state under the prompt is whatever `_at` is now.
    if (_flight != null) return Unlocking(wasUnlocked: at != null);
    return at == null ? const Locked() : Unlocked(at);
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
      state = Unlocked(at);
    } else {
      final at = _at;
      state = at == null ? const Locked() : Unlocked(at);
    }
    return outcome;
  }

  /// Gives the unlock back now (a "Lock" button, a sign-out). A prompt already up still ends, and
  /// a success then unlocks again.
  void lock() {
    _at = null;
    state = _flight == null ? const Locked() : const Unlocking();
  }

  /// Whether the app is unlocked and the unlock is younger than [maxAge] by `clock.now()`
  /// (without [maxAge], whether it is unlocked at all). Under a prompt that started over an unlock
  /// it answers for that unlock, so a guard that runs again during a [withBiometrics] sheet keeps its answer.
  bool isFresh({Duration? maxAge}) {
    final at = _at;
    if (at == null) return false;
    return maxAge == null || !_expired(at, maxAge);
  }
}

/// The policy for relocking (since 0.13.0); the default relocks on a return from the background 10 seconds or more after the unlock.
final biometricPolicy = Provider<BiometricPolicy>(
  (ref) => const BiometricPolicy(),
);
