/// Which of a device's two keys signs (since 0.21.0).
///
/// The two-key model of flutter-sign-keypair: a device holds an *ambient* key that signs silently,
/// on every request, and a *user-present* key that the secure element releases only after a live
/// human has unlocked it (a biometric, the device credential). They are two keys under two key
/// ids, because a platform stores the protection with the key.
enum KeyRole {
  /// Never prompts. Signs what happens in the background, on every request, or with no screen to
  /// show a prompt on (a renewal).
  ambient,

  /// Prompts on every signature. Signs what is worth interrupting the user for: a transfer, a
  /// security change. A platform with no secure element has none (the web, Windows, Linux), and
  /// asking for one there is refused, never answered with a key that does not prompt.
  userPresent,
}
