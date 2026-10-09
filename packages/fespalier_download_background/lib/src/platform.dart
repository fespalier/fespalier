import 'package:flutter/foundation.dart';

/// Which platform the backend runs on, as far as `background_downloader` is concerned (since
/// 0.15.0). A value, so a test can say "Android" without being on it.
enum BackgroundPlatform {
  /// Android: WorkManager, and user-initiated data transfer jobs on Android 14 and newer.
  android,

  /// iOS: a background `URLSession`.
  ios,

  /// macOS, Windows and Linux: the plugin downloads, but there is no operating-system
  /// background mode and no notification.
  desktop,

  /// The web and Fuchsia: the plugin does not run here, and every start ends
  /// `Failed(unsupported)`.
  unsupported;

  /// The platform this code runs on.
  static BackgroundPlatform get current {
    if (kIsWeb) return unsupported;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => android,
      TargetPlatform.iOS => ios,
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => desktop,
      TargetPlatform.fuchsia => unsupported,
    };
  }

  /// Whether the operating system keeps a transfer going while the app is away: Android and iOS.
  bool get isMobile => this == android || this == ios;
}
