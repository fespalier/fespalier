/// When the unlock is given back (since 0.13.0). Set once with `biometricPolicy.overrideWithValue`.
final class BiometricPolicy {
  /// Relocks when the app comes back from the background at least [resumeGrace] after the unlock.
  const BiometricPolicy({this.resumeGrace = const Duration(seconds: 10)});

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
}
