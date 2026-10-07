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
/// It relocks when the app resumes at least `BiometricPolicy.resumeGrace` after the unlock: `build`
/// watches core's `appResumeSignal`, so a resume runs it again, and it starts no timer and adds no
/// listener of its own. An unlock does not expire by itself: a `maxAge` is checked when a guard
/// runs or [isFresh] is asked, that is at the next navigation or resume.
class BiometricUnlock extends Notifier<UnlockState> {
  Future<BiometricOutcome>? _flight;
  DateTime? _at;

  @override
  UnlockState build() {
    ref.watch(appResumeSignal);
    final grace = ref.watch(biometricPolicy).resumeGrace;
    final at = _at;
    if (_flight != null) return Unlocking(wasUnlocked: at != null);
    if (at != null && clock.now().difference(at) < grace) return Unlocked(at);
    _at = null;
    return const Locked();
  }

  /// Asks the platform to check, and returns how it ended.
  ///
  /// Single-flight: while a prompt is up, a second call gets the same `Future`, so two buttons, a
  /// double tap or a guard that runs again never stack two sheets. A success is [Unlocked]; anything
  /// else leaves the state as it was before the call. [reason] is what the person reads. It never
  /// throws: a prompt that throws is [BiometricOutcome.failed].
  Future<BiometricOutcome> unlock(String reason) {
    final running = _flight;
    if (running != null) return running;
    final prompt = ref.read(biometricPrompt);
    final previous = _at;
    state = Unlocking(wasUnlocked: previous != null);
    return _flight = _run(prompt, reason, previous);
  }

  Future<BiometricOutcome> _run(
    BiometricPrompt prompt,
    String reason,
    DateTime? previous,
  ) async {
    // Not complete within the call, so `unlock` has set `_flight` before anything here can clear it.
    await null;
    final span = promptSpan();
    var outcome = BiometricOutcome.failed;
    try {
      outcome = await prompt.authenticate(reason);
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
      state = previous == null ? const Locked() : Unlocked(previous);
    }
    return outcome;
  }

  /// Gives the unlock back now (a "Lock" button, a sign-out). A prompt already up still ends.
  void lock() {
    _at = null;
    if (_flight == null) state = const Locked();
  }

  /// Whether the app is unlocked and the unlock is younger than [maxAge] by `clock.now()`
  /// (without [maxAge], whether it is unlocked at all).
  bool isFresh({Duration? maxAge}) {
    final current = state;
    final at = _at;
    if (current is! Unlocked || at == null) return false;
    return maxAge == null || clock.now().difference(at) < maxAge;
  }
}

/// The policy for relocking (since 0.13.0); the default relocks on a resume 10 seconds after the unlock.
final biometricPolicy = Provider<BiometricPolicy>(
  (ref) => const BiometricPolicy(),
);
