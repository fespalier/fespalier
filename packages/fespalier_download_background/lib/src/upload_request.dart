import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_http/fespalier_http.dart' show HttpWrites;

/// The HTTP method of an upload (since 0.15.0).
enum UploadMethod {
  /// `POST`: the default of a form or an API endpoint.
  post,

  /// `PUT`: a pre-signed object-store address, for one.
  put,
}

/// How the file travels in the request body (since 0.15.0).
enum UploadEncoding {
  /// `multipart/form-data`: the file under a field name, with optional text fields beside it.
  multipart,

  /// The file's bytes are the whole body.
  binary,
}

/// One file to send (since 0.15.0): where it is, where it goes, and how.
///
/// **Replay safety.** An upload is *replay safe* when sending it again cannot do harm, which is
/// `fespalier_http`'s rule for writes (`HttpWrites.isWrite`): it carries an `Idempotency-Key`
/// header. Every other upload is a write the server may already have taken, and `Uploads` treats it
/// that way: no retry, no re-send after a 401, and a restart that finds no answer ends it
/// `Failed`, never sends it again. See [replaySafe].
final class UploadRequest {
  /// A request. [id] names the upload for its whole life. Check [isValid] before using one that
  /// came from outside the app.
  const UploadRequest({
    required this.id,
    required this.url,
    required this.file,
    this.method = UploadMethod.post,
    this.encoding = UploadEncoding.multipart,
    this.fileField = 'file',
    this.fields = const {},
    this.headers = const {},
    this.network = DownloadNetwork.any,
    this.priority = DownloadPriority.background,
    this.displayName,
  });

  /// The app's key for this upload.
  final String id;

  /// Where to send it: an absolute http or https URL.
  final Uri url;

  /// The file to send, as a base folder and a relative path: never an absolute path. It must
  /// exist when the upload starts, and the upload never deletes it.
  final DownloadLocation file;

  /// `POST` or `PUT`.
  final UploadMethod method;

  /// Multipart (the default) or the file as the whole body.
  final UploadEncoding encoding;

  /// For a multipart upload, the name of the file's field.
  final String fileField;

  /// For a multipart upload, text fields sent beside the file. Empty for a binary upload.
  final Map<String, String> fields;

  /// Request headers. **A backend may keep them on disk in plaintext** while the upload is
  /// queued: never a long-lived credential or a refresh token. Add an `Idempotency-Key` to make
  /// the upload [replaySafe].
  final Map<String, String> headers;

  /// The networks the upload may use.
  final DownloadNetwork network;

  /// How urgent the upload is.
  final DownloadPriority priority;

  /// A name for a notification, when the app shows one. Never reported to telemetry.
  final String? displayName;

  /// Whether sending this upload again is harmless: it carries an `Idempotency-Key` header
  /// (`HttpWrites.isWrite` is false). Only a replay-safe upload is retried, re-sent after a 401
  /// or 403 with a renewed grant, or sent again by `Uploads.retry`.
  bool get replaySafe =>
      !HttpWrites.isWrite(method.name.toUpperCase(), headers.keys);

  /// Whether the request can be started: a non-empty [id]; an absolute http or https [url] with a
  /// host and no credentials in it; a valid [file]; header names that are not empty; and, for a
  /// multipart upload, a [fileField] and field names that are not empty and hold no quote, line
  /// break or NUL, or, for a binary one, no [fields].
  bool get isValid {
    if (id.isEmpty) return false;
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    if (url.host.isEmpty || url.userInfo.isNotEmpty) return false;
    if (!file.isValid) return false;
    if (headers.keys.any((name) => name.trim().isEmpty)) return false;
    if (encoding == UploadEncoding.binary) return fields.isEmpty;
    return _isFieldName(fileField) && fields.keys.every(_isFieldName);
  }

  /// This request with [url] in place of its own: the address a grant names for one attempt.
  UploadRequest withUrl(Uri url) => UploadRequest(
    id: id,
    url: url,
    file: file,
    method: method,
    encoding: encoding,
    fileField: fileField,
    fields: fields,
    headers: headers,
    network: network,
    priority: priority,
    displayName: displayName,
  );

  /// Prints no field: the URL can be a capability, the headers a credential, the fields and the
  /// name a person's own words.
  @override
  String toString() => 'UploadRequest';
}

bool _isFieldName(String name) =>
    name.isNotEmpty && !RegExp('["\r\n\u0000]').hasMatch(name);
