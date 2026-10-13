import 'location.dart';

/// Which networks a download may use (since 0.15.0).
enum DownloadNetwork {
  /// Any network, mobile data included.
  any,

  /// Only an unmetered network (Wi-Fi).
  unmetered,
}

/// How much the person is waiting for a download (since 0.15.0).
enum DownloadPriority {
  /// The person asked for it just now and watches it: a backend may start it at once and show it
  /// as such (Android's user-initiated jobs).
  userInitiated,

  /// The app wants it done when the system finds a moment.
  background,
}

final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

/// One file to fetch (since 0.15.0): where from, where to, and what it must be.
final class DownloadRequest {
  /// A request. [id] names the download for its whole life: starting the same id again is the
  /// same download. Check [isValid] before using one that came from outside the app.
  const DownloadRequest({
    required this.id,
    required this.url,
    required this.file,
    this.headers = const {},
    this.bytes,
    this.sha256,
    this.network = DownloadNetwork.any,
    this.priority = DownloadPriority.background,
    this.displayName,
  });

  /// The app's key for this download.
  final String id;

  /// Where to fetch from: an absolute http or https URL.
  final Uri url;

  /// Where to put the file.
  final DownloadLocation file;

  /// Request headers. **A backend may keep them on disk in plaintext** while the download is
  /// queued: never a long-lived credential or a refresh token. A short-lived URL is better.
  final Map<String, String> headers;

  /// The size the file must have, when known; a different size is a `sizeMismatch`.
  final int? bytes;

  /// The SHA-256 of the file as 64 hex digits, when known; a different digest is a
  /// `hashMismatch`.
  final String? sha256;

  /// The networks the download may use.
  final DownloadNetwork network;

  /// How urgent the download is.
  final DownloadPriority priority;

  /// A name for a notification, when the app shows one. Never reported to telemetry.
  final String? displayName;

  /// Whether the request can be started: a non-empty [id]; an absolute http or https [url] with
  /// a host and no credentials in it; a valid [file]; a non-negative [bytes]; a [sha256] of 64
  /// hex digits; and header names that are not empty.
  bool get isValid {
    if (id.isEmpty) return false;
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    if (url.host.isEmpty || url.userInfo.isNotEmpty) return false;
    if (!file.isValid) return false;
    final size = bytes;
    if (size != null && size < 0) return false;
    final digest = sha256;
    if (digest != null && !_hex64.hasMatch(digest)) return false;
    return !headers.keys.any((name) => name.trim().isEmpty);
  }

  /// Prints no field: the URL can be a capability, the headers a credential and the name a
  /// person's own words.
  @override
  String toString() => 'DownloadRequest';
}
