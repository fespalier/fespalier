import 'package:flutter/foundation.dart';

/// What to download for one file pack: a single file (a PMTiles archive, an MBTiles database)
/// fetched over HTTP, under a [key] of the app's choosing (since 0.13.0).
///
/// The app passes where the file lives: [destination] is a path in a directory the app owns (its
/// application-support directory, from `path_provider` or a platform channel of its own; this
/// package depends on no plugin for it). The file appears at [destination] **only when it is
/// whole and checked**: the bytes arrive in `<destination>.part`, and a transfer that is
/// interrupted leaves that file for the next attempt to continue with an HTTP `Range` request.
///
/// The [key], the [url], the paths and the [headers] are **never** sent to telemetry: a URL can
/// carry a token, and a key or a path often names a place.
///
/// ```dart
/// final request = FilePackRequest(
///   key: 'douala',
///   url: Uri.parse('https://tiles.example.com/douala-2026-10.pmtiles'),
///   destination: '/data/user/0/app/files/packs/douala.pmtiles',
///   bytes: 48213377,
///   sha256: 'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12',
/// );
/// request.isValid; // true
/// pmtilesSourceUrl(request.destination);
/// // 'pmtiles://file:///data/user/0/app/files/packs/douala.pmtiles'
/// ```
@immutable
final class FilePackRequest {
  /// A request for the file at [url], stored at [destination].
  const FilePackRequest({
    required this.key,
    required this.url,
    required this.destination,
    this.sha256,
    this.bytes,
    this.headers = const {},
  });

  /// The app's name for the pack. Must not be empty.
  final String key;

  /// Where the file is served from: `http` or `https`, with a host. The server should honour
  /// `Range`; if it does not, a transfer that is cut starts again from the first byte.
  final Uri url;

  /// The path of the finished file, in a directory the app owns. Two packs must not share one.
  final String destination;

  /// The file's SHA-256 as 64 hexadecimal digits (either case), checked before the file is moved
  /// to [destination]. Without it, the pack is checked by [bytes] alone, or not at all. The hash
  /// of a large file is computed after the last byte arrives and takes a moment.
  final String? sha256;

  /// The size the file must have, in bytes. It also lets the progress start at the first byte and
  /// lets a partial file that is already whole skip the network.
  final int? bytes;

  /// Extra request headers (an `Authorization` header, for example). `Range`, `If-Range` and
  /// `Accept-Encoding` are the package's own and replace the same names here.
  final Map<String, String> headers;

  /// Where the bytes arrive: [destination] plus `.part`.
  String get partial => '$destination.part';

  /// Where the validator of the partial file (the server's `ETag` or `Last-Modified`, which
  /// `If-Range` sends back) is kept: [partial] plus `.etag`.
  String get validator => '$partial.etag';

  /// Whether this can be downloaded: a key, an `http` or `https` URL with a host, a destination,
  /// a [bytes] above zero when given and a [sha256] of 64 hexadecimal digits when given.
  bool get isValid =>
      key.isNotEmpty &&
      (url.scheme == 'http' || url.scheme == 'https') &&
      url.host.isNotEmpty &&
      destination.isNotEmpty &&
      (bytes == null || bytes! > 0) &&
      (sha256 == null || _hex64.hasMatch(sha256!));

  static final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

  @override
  bool operator ==(Object other) =>
      other is FilePackRequest &&
      other.key == key &&
      other.url == url &&
      other.destination == destination &&
      other.sha256 == sha256 &&
      other.bytes == bytes &&
      mapEquals(other.headers, headers);

  @override
  int get hashCode =>
      Object.hash(key, url, destination, sha256, bytes, headers.length);

  // No fields in the text: the URL can carry a token, the key and the path name a place.
  @override
  String toString() => 'FilePackRequest';
}

/// The `pmtiles://` URL of the local archive at [path], for a style's vector source:
///
/// ```dart
/// pmtilesSourceUrl('/data/user/0/app/files/packs/douala.pmtiles');
/// // 'pmtiles://file:///data/user/0/app/files/packs/douala.pmtiles'
/// ```
///
/// A style that names it as the `"url"` of a `"type": "vector"` source draws from the file with
/// no network (the style JSON is the app's own; see the docs).
String pmtilesSourceUrl(String path) =>
    'pmtiles://${Uri.file(path, windows: false)}';
