/// A ready-made unlock page body in Material (since 0.19.0): [BiometricLockScreen].
///
/// This is the only library of the package that imports Material. `fespalier_biometrics.dart` and
/// everything under `lib/src/` stay free of it (`test/lock_screen_test.dart` reads them), so an app
/// that draws its own unlock page, or uses another widget set, takes no Material widget with it.
library;

import 'package:fespalier/fespalier.dart';
import 'fespalier_biometrics.dart';
import 'package:flutter/material.dart';

/// The words [BiometricLockScreen] shows (since 0.19.0), replaceable for another language.
final class BiometricLockScreenMessages {
  /// The defaults are English.
  const BiometricLockScreenMessages({
    this.unlock = 'Unlock',
    this.failed = 'Not recognised. Try again.',
    this.lockedOut = 'Too many tries. Unlock your device, then try again.',
    this.unavailable = 'This device cannot check a fingerprint or a face.',
  });

  /// The button's label.
  final String unlock;

  /// Shown after a prompt that did not pass ([BiometricOutcome.failed]); the button stays.
  final String failed;

  /// Shown after the platform refused to ask for now ([BiometricOutcome.lockedOut]).
  final String lockedOut;

  /// Shown instead of the button when the device cannot ask, unless the screen has an `unavailable`
  /// builder.
  final String unavailable;
}

/// The body of an app's unlock page (since 0.19.0): a button that asks for the biometric check, and
/// the words for how the last try ended.
///
/// **It prompts when the button is tapped and never otherwise.** Not in `build` (a rebuild is never a
/// prompt, which is the rule of the whole package), and not after the first frame either: the package
/// schedules no frame and starts no timer. An unlock page that should ask as soon as it opens does it
/// from its `observe.dart` `onEnter` hook, which fespalier runs after the frame
/// (`docs/guards.md`, "A ready-made unlock page"); the button is then the way to try again.
///
/// The page around it is the app's: it sits beside the guarded folder (a guard on the unlock page
/// would redirect to itself), and [onUnlocked] is where it goes back, usually
/// `context.go(returnTo(from))`.
///
/// - The button is disabled while a sheet is up (`Unlocking`), and a second tap would share the
///   sheet anyway: `unlock()` is single-flight.
/// - [BiometricOutcome.failed] and [BiometricOutcome.lockedOut] show their message; a cancel shows
///   nothing, because the person chose it.
/// - When `biometricAvailable` answers `false`, or a tap ends [BiometricOutcome.unavailable], the
///   button gives way to [unavailable] (or the message of the same name): "Use your passcode" is the
///   app's.
/// - It opens no dialog, route, menu, sheet or snack bar; the platform's own sheet is the prompt.
///
/// Rejected on purpose: a `BiometricGate` that overlays the whole app when it is locked. It would be
/// a second way to say "locked" beside the guard, and a subtree parked under an overlay keeps its
/// state, and so its secrets, in memory.
class BiometricLockScreen extends ConsumerStatefulWidget {
  /// A lock screen that asks with [reason] (what the person reads in the platform's sheet) and calls
  /// [onUnlocked] after a success.
  const BiometricLockScreen({
    super.key,
    required this.reason,
    required this.onUnlocked,
    this.title,
    this.unavailable,
    this.messages = const BiometricLockScreenMessages(),
  });

  /// What the platform's sheet says: "Unlock your vault".
  final String reason;

  /// Called once after a prompt succeeds, while the screen is still mounted.
  final VoidCallback onUnlocked;

  /// Shown above the button, when given.
  final Widget? title;

  /// Built instead of the button when the device cannot ask; defaults to a [Text] of
  /// [BiometricLockScreenMessages.unavailable].
  final WidgetBuilder? unavailable;

  /// The words, for another language.
  final BiometricLockScreenMessages messages;

  @override
  ConsumerState<BiometricLockScreen> createState() =>
      _BiometricLockScreenState();
}

class _BiometricLockScreenState extends ConsumerState<BiometricLockScreen> {
  BiometricOutcome? _last;
  // A second tap in the frame before the button is disabled would share the sheet and call
  // onUnlocked twice.
  bool _asking = false;

  Future<void> _unlock() async {
    if (_asking) return;
    _asking = true;
    setState(() => _last = null);
    final BiometricOutcome outcome;
    try {
      outcome = await ref.read(biometricUnlock.notifier).unlock(widget.reason);
    } finally {
      _asking = false;
    }
    if (!mounted) return;
    if (outcome == BiometricOutcome.success) {
      widget.onUnlocked();
    } else {
      setState(() => _last = outcome);
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    final unlocking = ref.watch(biometricUnlock) is Unlocking;
    // Only a plain "no" replaces the button: while the answer is pending, or if the plugin threw,
    // the button stays and a tap reports what happened.
    final available = ref.watch(biometricAvailable).value ?? true;
    final cannotAsk = !available || _last == BiometricOutcome.unavailable;
    final message = switch (_last) {
      BiometricOutcome.failed => messages.failed,
      BiometricOutcome.lockedOut => messages.lockedOut,
      _ => null,
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.title case final title?) ...[
              title,
              const SizedBox(height: 24),
            ],
            if (cannotAsk)
              widget.unavailable?.call(context) ?? Text(messages.unavailable)
            else ...[
              FilledButton(
                onPressed: unlocking ? null : _unlock,
                child: Text(messages.unlock),
              ),
              if (unlocking) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
              if (message != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
