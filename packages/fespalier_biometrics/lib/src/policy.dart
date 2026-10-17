/// When the unlock is given back (since 0.13.0). Set once with `biometricPolicy.overrideWithValue`.
final class BiometricPolicy {
  /// Relocks when the app comes back from the background at least [resumeGrace] after the unlock.
  const BiometricPolicy({
    this.resumeGrace = const Duration(seconds: 10),
    this.idleTimeout,
  });

  /// How long after the unlock the app may go to the background and come back with the unlock kept.
  /// A return from hidden (core's `appShowSignal`: `AppLifecycleListener.onShow`) at least this long
  /// after the unlock goes back to locked; a sooner one keeps it. [Duration.zero] relocks on every
  /// return from the background. Only a return from hidden counts: an iOS notification shade, Control
  /// Center, a call banner and the platform's own biometric sheet make the app inactive and back, which
  /// is not a return.
  ///
  /// **The default is a trade-off, not zero:** the platform's sheet and some system overlays can
  /// hide the app and show it just after the answer, so with zero an unlock could be undone by the
  /// sheet that gave it. The price is a window of [resumeGrace] after each unlock in which putting the
  /// app in the background and bringing it back does not ask again. An app that guards something
  /// worth more than that window sets a shorter grace (or [Duration.zero]) and tests it on a device.
  final Duration resumeGrace;

  /// Locks after this long without a touch or a hardware key (since 0.19.0); null, the default, is no
  /// idle lock. **Typing on a soft keyboard is not activity** (it does not reach Flutter as key events):
  /// a text field calls `ref.read(biometricUnlock.notifier).touch()` from its `onChanged`.
  ///
  /// The age is counted from the later of the unlock and the last activity that `BiometricActivity`
  /// recorded, by `package:clock`; a negative age (the clock was set back) counts as idle, like the
  /// grace. It takes effect in three places, none of them a timer of this package: a tick of
  /// `biometricIdleTicker` (the app fires it from its own timer), the first touch after the limit
  /// (`BiometricActivity` swallows it and locks), and the next navigation (`requireUnlocked` and
  /// `isFresh` read the age). The lock waits for the first tick after the limit, so any setup locks up
  /// to one ticker period late; a period of at most `idleTimeout / 4` bounds that. Must be positive
  /// (`BiometricUnlock` asserts it when it builds, in debug: a const constructor cannot compare
  /// durations): zero would absorb and lock on every touch.
  final Duration? idleTimeout;
}
