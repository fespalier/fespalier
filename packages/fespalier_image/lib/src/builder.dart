import 'request.dart';

/// Signs [payload], what the builder documents, and returns what goes in the URL (since 0.9.0).
///
/// Called synchronously while a widget builds: it must return at once. It must never hold a CDN
/// secret in an app: a key in an app binary or in `main.dart.js` is public, and with it anyone
/// signs any URL (README, "Signed image URLs"). Look a signature up instead, or let the backend
/// send signed URLs (a srcset, `SrcsetUrlBuilder`).
typedef ImageSigner = String Function(String payload);

/// Makes the URL of an [ImageRequest] for one CDN (since 0.9.0). Subclass it for a CDN that isn't
/// built in.
abstract class ImageUrlBuilder {
  /// Builders are const.
  const ImageUrlBuilder();

  /// The URL of [request]. Throws an [ImageUrlError] when the builder is misconfigured.
  String url(ImageRequest request);

  /// A short name, for telemetry (`fespalier.image.cdn`): `imgproxy`, `emgr`, `cloudinary`, ...
  String get name;

  /// Whether the CDN returns the width asked for. When false, the widget decodes at that width
  /// (`ResizeImage`), so an original is never held in memory at full size.
  bool get resizes => true;

  /// The widths [source] exists at (a srcset), used instead of the buckets; null for any width.
  List<int>? widthsOf(String source) => null;
}

/// A builder or the buckets are misconfigured: a bug in the app, not a network failure
/// (since 0.9.0).
final class ImageUrlError extends Error {
  /// An error that says [message].
  ImageUrlError(this.message);

  /// What is wrong, and how to fix it.
  final String message;

  @override
  String toString() => message;
}
