import 'package:fespalier_download/fespalier_download.dart';

import 'upload_request.dart';

/// What an [UploadBackend] tells the engine (since 0.15.0).
abstract interface class UploadEvents {
  /// The upload [id] is now in [status]. [httpStatus] is the server's status code when the
  /// backend has one (the engine reads 401 and 403 from it). A `Complete` carries the file that
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

/// The durable list of uploads the app asked for (since 0.15.0): not a cache, nothing is evicted,
/// and only [clear] (sign-out) or [remove] drops an entry. It is what lets the engine say, after
/// a restart, that an upload it knows ended without an answer.
abstract interface class UploadStore {
  /// Every entry, by upload id.
  Future<Map<String, StoredUpload>> load();

  /// Adds or replaces an entry.
  Future<void> put(StoredUpload upload);

  /// Drops the entry [id].
  Future<void> remove(String id);

  /// Drops every entry.
  Future<void> clear();
}
