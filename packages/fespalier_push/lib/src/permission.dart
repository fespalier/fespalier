/// What the user answered to the platform's notification prompt (since 0.13.0).
enum PushPermission {
  /// Notifications are allowed.
  granted,

  /// iOS delivers quietly until the user decides (provisional authorization).
  provisional,

  /// The user refused, or turned notifications off in the settings.
  denied,

  /// The prompt has not been shown yet.
  notDetermined,
}
