/// When the unlock is given back (since 0.13.0). Set once with `biometricPolicy.overrideWithValue`.
final class BiometricPolicy {
  /// Relocks on a resume at least [resumeGrace] after the unlock.
  const BiometricPolicy({this.resumeGrace = const Duration(seconds: 10)});

  /// A resume (the app comes back to the foreground) at least this long after the unlock goes back to
  /// locked; a sooner one keeps the unlock. [Duration.zero] relocks on every resume.
  ///
  /// The default is not zero because the platform's own sheet pauses the app and the resume can land
  /// just after the prompt's answer: with zero, an unlock could be undone by the sheet that gave it.
  final Duration resumeGrace;
}
