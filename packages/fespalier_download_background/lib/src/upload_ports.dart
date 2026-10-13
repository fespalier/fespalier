import 'package:fespalier_download/fespalier_download.dart';

import 'upload_request.dart';

/// What an [UploadBackend] tells the engine (since 0.15.0).
abstract interface class UploadEvents {
  /// The upload [id] is now in [status]. [httpStatus] is the server's status code when the
  /// backend has one. The engine reads 401 and 403 from it, and, since 0.16.0, ends a
  /// `Failed(rejected)` whose [httpStatus] is a `5xx`, `408` or `499` as `Failed(other)`: only a
  /// client error proves the server did not apply the write. A `Complete` carries the file that
  /// was sent, which stays where it was.
  void status(String id, DownloadStatus status, {int? httpStatus});
}

/// The transfer machinery behind `Uploads` (since 0.15.0): the operating system's upload service,
/// or a fake. There is no pause and no resume (the plugin cannot pause an upload), and nothing here
/// deletes the file that is sent.
abstract interface class UploadBackend {
  /// What this backend can do. `pause` is always false.
  DownloadCapabilities get capabilities;

  /// Starts listening to the platform and reports through [events]. Called once, before any
  /// other method.
  Future<void> open(UploadEvents events);

  /// Stops listening. The transfers the platform owns go on.
  Future<void> close();

  /// Queues [request]. [authorization] is extra headers for this attempt only, never stored by
  /// the engine. A backend lets the platform send the upload again after a failed attempt **only
  /// when [UploadRequest.replaySafe]**. False when the backend refuses the request.
  Future<bool> enqueue(
    UploadRequest request, {
    Map<String, String> authorization = const {},
  });

  /// Stops the upload [id] and forgets it.
  Future<void> cancel(String id);

  /// Stops every upload this backend owns.
  Future<void> cancelAll();

  /// Sets the notification texts, or turns notifications off with null.
  Future<void> configureNotifications(DownloadNotifications? notifications);
}

/// An upload as the registry keeps it (since 0.15.0).
final class StoredUpload {
  /// A registry entry: the [request] and the [generation] of its current attempt.
  const StoredUpload(this.request, {this.generation = 0});

  /// What was asked.
  final UploadRequest request;

  /// Counts the attempts, so a late event of an old attempt can be told from the current one.
  final int generation;

  /// Prints no field: the request holds a URL and headers.
  @override
  String toString() => 'StoredUpload';
}

/// An [UploadStore] could not read or keep the registry (since 0.16.0). The text is constant and
/// names no path, no id and no URL.
final class UploadStoreException implements Exception {
  /// An exception with a constant [message].
  const UploadStoreException(this.message);

  /// What could not be done.
  final String message;

  @override
  String toString() => 'UploadStoreException: $message';
}

/// The durable list of uploads the app asked for (since 0.15.0): not a cache, nothing is evicted,
/// and only [clear] (sign-out) or [remove] drops an entry. It is what lets the engine say, after
/// a restart, that an upload it knows ended without an answer.
///
/// **A failure is reported, never swallowed** (since 0.16.0), because the registry is the only
/// thing that remembers an upload may have been sent: [load] throws when the registry exists and
/// cannot be read (it is not an empty one), and [put] throws when the entry was not kept. `Uploads`
/// ends an upload whose entry could not be kept `Failed(storage)` **before** it is handed to the
/// platform, and, with a registry it could not read, starts no upload without an
/// `Idempotency-Key`. [remove] and [clear] may throw too; `Uploads` does not let that stop a cancel
/// or a sign-out.
abstract interface class UploadStore {
  /// Every entry, by upload id. Throws when the registry cannot be read.
  Future<Map<String, StoredUpload>> load();

  /// Adds or replaces an entry. Throws when it could not be kept.
  Future<void> put(StoredUpload upload);

  /// Drops the entry [id].
  Future<void> remove(String id);

  /// Drops every entry.
  Future<void> clear();
}
