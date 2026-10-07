import 'package:fespalier/fespalier.dart';

import 'unlock.dart';

/// What a guard watches: unlocked, or a prompt up over an unlock (so a [withBiometrics] on an open
/// page never sends the person to the unlock page while the sheet is showing).
bool _open(UnlockState state) => switch (state) {
  Unlocked() => true,
  Unlocking(:final wasUnlocked) => wasUnlocked,
  Locked() => false,
};

/// A guard.dart's answer for a route behind the biometric unlock (since 0.13.0): null while
/// unlocked, otherwise the location of the app's unlock page with the `from` it should return to.
///
/// ```dart
/// GuardResult guard(Ref ref, {required Uri uri}) =>
///     requireUnlocked(ref, uri, unlock: (from) => UnlockRoute(from: from));
/// ```
///
/// **It never prompts.** It reads the state and answers at once (synchronously, so it composes with
/// `??`); the unlock page calls `ref.read(biometricUnlock.notifier).unlock(reason)` and then goes to
/// `returnTo(from)`. So a guard that runs again, for any reason, cannot show a second sheet. It
/// watches only whether the app is unlocked, so a prompt coming and going does not run it again;
/// a lock, or a relock by the policy, does, and the router leaves the page.
///
/// With [maxAge] the unlock must also be younger than that, by `package:clock`, when the guard runs:
/// an expiry takes effect when the guard next runs (the next navigation, or a re-run because what it
/// watches changed), never by itself: there is no timer, so a page already open stays open.
GuardResult requireUnlocked(
  Ref ref,
  Uri uri, {
  required TypedLocation Function(String from) unlock,
  Duration? maxAge,
}) {
  final open = ref.watch(biometricUnlock.select(_open));
  final fresh =
      open &&
      (maxAge == null ||
          ref.read(biometricUnlock.notifier).isFresh(maxAge: maxAge));
  return fresh ? null : unlock(uri.toString()).location;
}
