import 'dart:async';

import 'request.dart';

/// What the app got from its server for one download (since 0.15.0): a short-lived address of
/// one file, and/or headers that are good for that download alone.
///
/// A grant is made in the foreground, with the app's own signed request (a `fespalier_http`
/// client, so the session's credentials and proofs apply there), and it is the only credential the
/// transfer carries: the operating system's download service sends it later with no access to the
/// app's session. Make it expire in minutes and name one file; **never put a refresh token or a
/// long-lived bearer in one**, because a background backend may keep a request in plaintext on
/// disk while the download is queued.
///
/// The engine never stores a grant (the registry keeps the request as the app made it), and
/// [toString] prints no field.
final class DownloadGrant {
  /// A grant. [url] replaces the request's address for this attempt (an absolute http or https
  /// URL), [headers] are added to the request's own for this attempt.
  const DownloadGrant({this.url, this.headers = const {}});

  /// The short-lived address of the file, or null to keep the request's own.
  final Uri? url;

  /// Headers for this attempt only, or none.
  final Map<String, String> headers;

  /// [request] as it goes to the backend for this attempt: the same download (id, file, size,
  /// digest) with this grant's [url] in place of its own. A grant without a [url] returns the
  /// request as it is.
  DownloadRequest applyTo(DownloadRequest request) {
    final granted = url;
    if (granted == null) return request;
    return DownloadRequest(
      id: request.id,
      url: granted,
      file: request.file,
      headers: request.headers,
      bytes: request.bytes,
      sha256: request.sha256,
      network: request.network,
      priority: request.priority,
      displayName: request.displayName,
    );
  }

  /// Prints no field: the URL is a capability and the headers a credential.
  @override
  String toString() => 'DownloadGrant';
}

/// Asks the app for a [DownloadGrant] (since 0.15.0), in the foreground, before an attempt.
///
/// [request] is the download as the app registered it. [renewal] is false for the grant that
/// goes with a start, a retry or a resume, and true for the one that follows a 401 or 403: the
/// engine asks for it **once** per attempt chain, and a second refusal ends the download
/// `Failed(unauthorized)`.
///
/// Return null to send the request as it is. A throw ends the download
/// `Failed(unauthorized)` (the engine never crashes on it and keeps nothing of the error). Make
/// the signed request with the app's session here, and return only what the server meant for this
/// file.
///
/// ```dart
/// Future<DownloadGrant?> grant(
///   DownloadRequest request, {
///   required bool renewal,
/// }) async {
///   final answer = await signedClient.post(grantUrl(request.id));
///   return DownloadGrant(url: Uri.parse(urlOf(answer)));
/// }
/// ```
typedef DownloadGrantor =
    FutureOr<DownloadGrant?> Function(
      DownloadRequest request, {
      required bool renewal,
    });
