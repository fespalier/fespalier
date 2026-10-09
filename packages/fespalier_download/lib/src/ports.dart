import 'location.dart';
import 'request.dart';
import 'status.dart';

/// What a [DownloadBackend] can do on this platform (since 0.15.0). The engine asks instead of
/// guessing, and a backend that cannot do a thing says so.
final class DownloadCapabilities {
  /// Capabilities. Every flag defaults to false: a backend lists what it has.
  const DownloadCapabilities({
    this.pause = false,
    this.resumeAcrossRestart = false,
    this.background = false,
    this.userInitiated = false,
    this.unmetered = false,
    this.notifications = false,
  });

  /// A transfer can be paused and resumed.
  final bool pause;

  /// A transfer survives the app being closed and goes on from the bytes it has.
  final bool resumeAcrossRestart;

  /// A transfer goes on while the app is in the background.
  final bool background;

  /// [DownloadPriority.userInitiated] is honoured as such.
  final bool userInitiated;

  /// [DownloadNetwork.unmetered] is honoured.
  final bool unmetered;

  /// The backend can show notifications for a transfer.
  final bool notifications;
}

/// What a notification tap asks for (since 0.15.0).
enum DownloadTapKind {
  /// The person tapped the notification's body.
  body,

  /// The person tapped an action on the notification.
  action,
}

/// The texts of a download's notifications (since 0.15.0). Null means no notification: the
/// package never asks for the permission, the app does.
final class DownloadNotifications {
  /// Notification texts. A null text leaves that state without a notification.
  const DownloadNotifications({
    this.running,
    this.paused,
    this.complete,
    this.failed,
  });

  /// While the transfer runs.
  final String? running;

  /// While it is paused.
  final String? paused;

  /// When it completes.
  final String? complete;

  /// When it fails.
  final String? failed;
}

/// What a backend tells the engine (since 0.15.0).
abstract interface class DownloadEvents {
  /// The download [id] is now in [status]. [httpStatus] is the server's status code when the
  /// backend has one (the engine reads 401 and 403 from it).
  void status(String id, DownloadStatus status, {int? httpStatus});

  /// The person tapped the notification of the download [id].
  void tapped(String id, DownloadTapKind kind);
}

/// The transfer machinery behind the engine (since 0.15.0): a foreground HTTP client, or the
/// operating system's download service. One method per thing the engine may ask; a refusal is
/// a `false` or a status event, never an error the engine has to read.
abstract interface class DownloadBackend {
  /// What this backend can do.
  DownloadCapabilities get capabilities;

  /// Starts listening to the platform and reports through [events]. Called once, before any
  /// other method.
  Future<void> open(DownloadEvents events);

  /// Stops listening. The transfers the platform owns go on.
  Future<void> close();

  /// Queues [request]. [authorization] is extra headers for this attempt only, never stored by
  /// the engine. False when the backend refuses the request.
  Future<bool> enqueue(
    DownloadRequest request, {
    Map<String, String> authorization = const {},
  });

  /// Pauses the download [id]. False when it cannot be paused.
  Future<bool> pause(String id);

  /// Resumes the download [id], with fresh [authorization] headers when it needs them. False
  /// when it cannot be resumed.
  Future<bool> resume(
    String id, {
    Map<String, String> authorization = const {},
  });

  /// Stops the download [id] and removes what it kept.
  Future<void> cancel(String id);

  /// Stops every download this backend owns.
  Future<void> cancelAll();

  /// The absolute path of [location] on this device, for the moment of use only: never store it.
  Future<String> resolve(DownloadLocation location);

  /// Sets the notification texts, or turns notifications off with null.
  Future<void> configureNotifications(DownloadNotifications? notifications);
}

/// A download as the registry keeps it (since 0.15.0).
final class StoredDownload {
  /// A registry entry: the [request] and the [generation] of its current attempt.
  const StoredDownload(this.request, {this.generation = 0});

  /// What was asked.
  final DownloadRequest request;

  /// Counts the attempts, so a late event of an old attempt can be told from the current one.
  final int generation;

  /// The same entry for the next attempt.
  StoredDownload next() => StoredDownload(request, generation: generation + 1);

  /// Prints no field: the request holds a URL and headers.
  @override
  String toString() => 'StoredDownload';
}

/// The durable list of downloads the app asked for (since 0.15.0). It is not a cache: nothing
/// is evicted, and only [clear] (sign-out) or [remove] drops an entry.
abstract interface class DownloadStore {
  /// Every entry, by download id.
  Future<Map<String, StoredDownload>> load();

  /// Adds or replaces an entry.
  Future<void> put(StoredDownload download);

  /// Drops the entry [id].
  Future<void> remove(String id);

  /// Drops every entry.
  Future<void> clear();
}

/// The files a download leaves behind (since 0.15.0): what the engine checks and deletes.
abstract interface class DownloadFiles {
  /// Whether a file is there.
  Future<bool> exists(DownloadLocation location);

  /// The size of the file, or null when there is none.
  Future<int?> length(DownloadLocation location);

  /// Deletes the file and anything partial next to it. Not an error when there is none.
  Future<void> delete(DownloadLocation location);
}
