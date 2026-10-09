import 'dart:convert';

import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:fespalier_download/fespalier_download.dart';

/// The group of every task this package enqueues (since 0.15.0). The plugin routes a task's
/// updates by its group: because this group has callbacks registered, its updates never reach
/// the app's own `FileDownloader().updates` stream, and the app's tasks never reach this package.
const String backgroundDownloadGroup = 'fespalier.download';

/// The priority of a [DownloadPriority.background] task: the plugin's own default. A
/// [DownloadPriority.userInitiated] task has priority 0, which is what the plugin runs as a
/// user-initiated data transfer job on Android 14 and newer (when a notification is configured and
/// the app declared the job service), and as a plain high-priority task elsewhere.
const int backgroundPriority = 5;

/// The priority of a [DownloadPriority.userInitiated] task.
const int userInitiatedPriority = 0;

/// How the backend sets up its tasks (since 0.15.0).
final class BackgroundOptions {
  /// Options. [retries] is how many times the operating system side retries a failed attempt with
  /// an exponential backoff, from 0 (never) to 10; [group] is the plugin group of every task.
  ///
  /// **A retry sends the headers the task was enqueued with**, not new ones: with a short-lived
  /// grant in them a retry can arrive after the grant expired. Use 0 where that matters.
  const BackgroundOptions({
    this.retries = 3,
    this.group = backgroundDownloadGroup,
  }) : assert(retries >= 0 && retries <= 10, 'retries is 0 through 10');

  /// The retries of a task.
  final int retries;

  /// The plugin group of every task; callbacks are registered for this group only.
  final String group;
}

/// Bytes received and the size when the server said it (since 0.15.0).
final class Progress {
  /// Progress.
  const Progress(this.received, [this.total]);

  /// Nothing received yet.
  static const Progress none = Progress(0);

  /// Bytes received. 0 when the size is not known: the plugin reports a fraction of the size.
  final int received;

  /// The size, or null.
  final int? total;

  @override
  bool operator ==(Object other) =>
      other is Progress && other.received == received && other.total == total;

  @override
  int get hashCode => Object.hash(received, total);

  @override
  String toString() => 'Progress($received/${total ?? '?'})';
}

/// A status and the HTTP status code that came with it, when there is one (since 0.15.0).
final class MappedStatus {
  /// A mapped status.
  const MappedStatus(this.status, {this.httpStatus});

  /// The status for the engine.
  final DownloadStatus status;

  /// The server's status code of a refusal.
  final int? httpStatus;
}

/// What the file must be, kept in the plugin task's `metaData` so that a download that finished
/// while the app was away is checked when the app is back (since 0.15.0). Size and digest are not
/// secrets; the URL and the headers are not in it.
final class TaskExpectation {
  /// An expectation of [bytes] bytes and the digest [sha256] (64 hex digits), either optional.
  const TaskExpectation({this.bytes, this.sha256});

  /// What a task with no expectation carries.
  static const TaskExpectation none = TaskExpectation();

  /// Reads a `metaData` string. Anything that is not an expectation (an app's own text, a
  /// malformed value) is [none]: this never throws.
  factory TaskExpectation.decode(String metaData) {
    if (metaData.isEmpty) return none;
    try {
      final json = jsonDecode(metaData);
      if (json is! Map<String, dynamic>) return none;
      final b = json['b'];
      final h = json['h'];
      return TaskExpectation(
        bytes: b is int && b >= 0 ? b : null,
        sha256: h is String && h.length == 64 ? h : null,
      );
    } on FormatException {
      return none;
    }
  }

  /// The size the file must have, or null.
  final int? bytes;

  /// The SHA-256 the file must have, or null.
  final String? sha256;

  /// Whether there is nothing to check.
  bool get isEmpty => bytes == null && sha256 == null;

  /// The `metaData` string: empty when there is nothing to check.
  String encode() {
    if (isEmpty) return '';
    return jsonEncode({
      if (bytes != null) 'b': bytes,
      if (sha256 != null) 'h': sha256,
    });
  }
}

/// The plugin's base folder for [base] (since 0.15.0): `support` is the application support
/// folder, `cache` the temporary one and `documents` the documents folder.
bd.BaseDirectory baseDirectoryOf(DownloadBase base) => switch (base) {
  DownloadBase.support => bd.BaseDirectory.applicationSupport,
  DownloadBase.cache => bd.BaseDirectory.temporary,
  DownloadBase.documents => bd.BaseDirectory.applicationDocuments,
};

/// Where the plugin task [task] puts its file, as a base and a relative path, or null for a task
/// outside the three bases (the plugin's library and root folders are not ours).
DownloadLocation? locationOf(bd.Task task) {
  final base = switch (task.baseDirectory) {
    bd.BaseDirectory.applicationSupport => DownloadBase.support,
    bd.BaseDirectory.temporary => DownloadBase.cache,
    bd.BaseDirectory.applicationDocuments => DownloadBase.documents,
    bd.BaseDirectory.applicationLibrary || bd.BaseDirectory.root => null,
  };
  if (base == null) return null;
  final directory = task.directory;
  final path = directory.isEmpty
      ? task.filename
      : '${directory.endsWith('/') ? directory.substring(0, directory.length - 1) : directory}/${task.filename}';
  final location = DownloadLocation(base, path);
  return location.isValid ? location : null;
}

// The plugin splits a file into a sub-folder and a name; the name may not hold a separator.
(String directory, String filename) _split(String path) {
  final cut = path.lastIndexOf('/');
  if (cut < 0) return ('', path);
  return (path.substring(0, cut), path.substring(cut + 1));
}

/// The plugin task for [request] (since 0.15.0).
///
/// - The task id is the request id; the group is [BackgroundOptions.group]; updates are status
///   and progress.
/// - The file is the request's base and relative path, as the plugin's base folder, sub-folder
///   and file name: never an absolute path.
/// - `userInitiated` is priority 0 (a user-initiated data transfer job on Android 14 and newer
///   when a notification is configured), `background` is the plugin's default 5. Both allow pause,
///   which is also what lets the plugin resume across WorkManager's nine-minute cycles. **Nothing
///   here asks for a foreground service**: the plugin's `runInForeground` configuration is never
///   set.
/// - `unmetered` is `requiresWiFi`.
/// - The headers are the request's, then [authorization] over them. They are written to the
///   operating system's task queue in plaintext until the task ends.
/// - The size and digest go into `metaData` ([TaskExpectation]).
///
/// The request must be valid ([DownloadRequest.isValid]).
bd.DownloadTask downloadTaskOf(
  DownloadRequest request, {
  Map<String, String> authorization = const {},
  BackgroundOptions options = const BackgroundOptions(),
}) {
  final (directory, filename) = _split(request.file.path);
  return bd.DownloadTask(
    taskId: request.id,
    url: request.url.toString(),
    headers: {...request.headers, ...authorization},
    filename: filename,
    directory: directory,
    baseDirectory: baseDirectoryOf(request.file.base),
    group: options.group,
    updates: bd.Updates.statusAndProgress,
    requiresWiFi: request.network == DownloadNetwork.unmetered,
    retries: options.retries,
    allowPause: true,
    priority: request.priority == DownloadPriority.userInitiated
        ? userInitiatedPriority
        : backgroundPriority,
    displayName: request.displayName ?? '',
    metaData: TaskExpectation(
      bytes: request.bytes,
      sha256: request.sha256?.toLowerCase(),
    ).encode(),
  );
}

/// A task that only names [location], to ask the plugin for its absolute path
/// (`Task.filePath`): never enqueued.
bd.DownloadTask pathProbeOf(DownloadLocation location) {
  final (directory, filename) = _split(location.path);
  return bd.DownloadTask(
    url: 'https://fespalier.invalid/',
    filename: filename,
    directory: directory,
    baseDirectory: baseDirectoryOf(location.base),
  );
}

/// The progress a plugin update stands for, or null for the special values the plugin sends with
/// an end state (a negative fraction). [fraction] is 0 through 1 and [expectedFileSize] is the
/// size or -1.
Progress? progressOf(double fraction, int expectedFileSize) {
  if (fraction.isNaN || fraction < 0) return null;
  final total = expectedFileSize > 0 ? expectedFileSize : null;
  if (total == null) return Progress.none;
  final received = (fraction.clamp(0.0, 1.0) * total).round();
  return Progress(received, total);
}

/// [progressOf] for a progress update.
Progress? progressOfUpdate(bd.TaskProgressUpdate update) =>
    progressOf(update.progress, update.expectedFileSize);

/// The failure of a failed plugin update, and the HTTP status code when the server refused
/// (since 0.15.0).
///
/// 401 and 403 are `unauthorized`; any other HTTP error is `rejected` (a 404 is the plugin's
/// `notFound`); a connection error is `network`; a file system error `storage`; a bad URL
/// `invalidRequest`; a resume that could not be done `killed`; anything else `other`. Only the
/// exception's type and its code are read: **never its text**.
(DownloadFailure, int?) failureOf(
  bd.TaskException? exception, {
  int? responseStatusCode,
}) {
  int? code;
  if (exception is bd.TaskHttpException) code = exception.httpResponseCode;
  code ??= responseStatusCode;
  if (code != null && code >= 400) {
    return (
      code == 401 || code == 403
          ? DownloadFailure.unauthorized
          : DownloadFailure.rejected,
      code,
    );
  }
  return switch (exception) {
    bd.TaskConnectionException() => (DownloadFailure.network, null),
    bd.TaskFileSystemException() => (DownloadFailure.storage, null),
    bd.TaskUrlException() => (DownloadFailure.invalidRequest, null),
    bd.TaskResumeException() => (DownloadFailure.killed, null),
    _ => (DownloadFailure.other, null),
  };
}

/// The status a plugin status update stands for (since 0.15.0), or null for an update that says
/// nothing.
///
/// [known] is the last progress seen for the task: a status carries none, and `running` and
/// `paused` report it. A `complete` update maps to `Complete` with [completeBytes]; the backend
/// checks the file before it reports that.
MappedStatus? downloadStatusOf(
  bd.TaskStatusUpdate update, {
  Progress known = Progress.none,
  int completeBytes = 0,
}) {
  switch (update.status) {
    case bd.TaskStatus.enqueued:
      return const MappedStatus(Queued());
    case bd.TaskStatus.running:
      return MappedStatus(Running(known.received, known.total));
    case bd.TaskStatus.waitingToRetry:
      return const MappedStatus(Waiting(WaitReason.retry));
    case bd.TaskStatus.paused:
      return MappedStatus(Paused(known.received, known.total));
    case bd.TaskStatus.canceled:
      return const MappedStatus(Cancelled());
    case bd.TaskStatus.notFound:
      return const MappedStatus(
        Failed(DownloadFailure.rejected),
        httpStatus: 404,
      );
    case bd.TaskStatus.failed:
      final (failure, http) = failureOf(
        update.exception,
        responseStatusCode: update.responseStatusCode,
      );
      return MappedStatus(Failed(failure), httpStatus: http);
    case bd.TaskStatus.complete:
      final location = locationOf(update.task);
      if (location == null) {
        return const MappedStatus(Failed(DownloadFailure.other));
      }
      return MappedStatus(Complete(location, completeBytes));
  }
}

/// The texts of the notifications of the group, as the plugin wants them (since 0.15.0).
final class NotificationPlan {
  /// A plan.
  const NotificationPlan({
    this.running,
    this.paused,
    this.complete,
    this.error,
  });

  /// While the transfer runs.
  final bd.TaskNotification? running;

  /// While it is paused.
  final bd.TaskNotification? paused;

  /// When it completes.
  final bd.TaskNotification? complete;

  /// When it fails.
  final bd.TaskNotification? error;

  /// Whether the plan shows anything.
  bool get isEmpty =>
      running == null && paused == null && complete == null && error == null;

  /// Whether the plan has the notification Android's user-initiated jobs require: one while the
  /// transfer runs.
  bool get hasRunning => running != null;
}

/// The plugin's notification texts for [notifications] (since 0.15.0), or an empty plan for null.
/// The title is the text the app gave and the body is the task's `displayName`
/// (`{displayName}`), so an app sets the name per download and the text once.
NotificationPlan notificationPlanOf(DownloadNotifications? notifications) {
  if (notifications == null) return const NotificationPlan();
  bd.TaskNotification? of(String? text) =>
      text == null ? null : bd.TaskNotification(text, '{displayName}');
  return NotificationPlan(
    running: of(notifications.running),
    paused: of(notifications.paused),
    complete: of(notifications.complete),
    error: of(notifications.failed),
  );
}
