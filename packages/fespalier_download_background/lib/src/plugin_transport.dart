import 'package:background_downloader/background_downloader.dart' as bd;

import 'mapping.dart';
import 'transport.dart';
import 'upload_transport.dart';

/// The `background_downloader` plugin as a [BackgroundTransport] (since 0.15.0): the one file
/// that calls it. **No CI job runs it** (there is no device in CI): it is a thin forwarding layer,
/// and everything with logic in it is in `mapping.dart` and the backend, which tests drive through
/// `FakeBackgroundTransport`. `docs/downloads.md` lists what only a device can show.
///
/// What it never does, and `test/no_timers_test.dart` greps for:
///
/// - listen to `FileDownloader().updates`, which is a single-subscription stream and the app's;
/// - call the plugin's global `start`, `reset`, `destroy` or `configure`, or `resetUpdates`;
/// - call `rescheduleKilledTasks`, which has no group parameter and would enqueue the app's own
///   tracked tasks again;
/// - set a configuration the app did not (no `runInForeground`, no holding queue).
///
/// It registers callbacks, tracks tasks and configures notifications for its own group only.
final class PluginTransport implements BackgroundTransport {
  /// A transport over `FileDownloader()`, or over [downloader] (the plugin's scoped or test
  /// instance).
  PluginTransport([bd.FileDownloader? downloader]) : _downloader = downloader;

  bd.FileDownloader? _downloader;

  // Created on first use, so that building a backend touches nothing of the plugin.
  bd.FileDownloader get _d => _downloader ??= bd.FileDownloader();

  @override
  void register(
    String group, {
    required void Function(bd.TaskStatusUpdate update) onStatus,
    required void Function(bd.TaskProgressUpdate update) onProgress,
    required void Function(bd.Task task, bd.NotificationType type) onTap,
  }) {
    _d.registerCallbacks(
      group: group,
      taskStatusCallback: onStatus,
      taskProgressCallback: onProgress,
      taskNotificationTapCallback: onTap,
    );
  }

  @override
  void unregister(String group) {
    _d.unregisterCallbacks(group: group);
  }

  @override
  Future<void> track(String group) async {
    await _d.trackTasksInGroup(group);
  }

  @override
  Future<void> resumeFromBackground() => _d.resumeFromBackground();

  @override
  Future<List<bd.TaskRecord>> records(String group) async {
    await _d.ready;
    return _d.database.allRecords(group: group);
  }

  @override
  Future<Set<String>> activeIds(String group) async =>
      (await _d.allTaskIds(group: group)).toSet();

  @override
  Future<bd.DownloadTask?> taskOf(String id) async {
    final task =
        (await _d.database.recordForId(id))?.task ?? await _d.taskForId(id);
    return task is bd.DownloadTask ? task : null;
  }

  @override
  Future<bool> enqueue(bd.DownloadTask task) => _d.enqueue(task);

  @override
  Future<bool> pause(bd.DownloadTask task) => _d.pause(task);

  @override
  Future<bool> resume(bd.DownloadTask task) => _d.resume(task);

  @override
  Future<void> cancel(String id) async {
    await _d.cancelTaskWithId(id);
    await _d.database.deleteRecordWithId(id);
  }

  @override
  Future<void> cancelAll(String group) async {
    await _d.ready;
    final records = await _d.database.allRecords(group: group);
    // A paused task is in no queue: the records name it too.
    final ids = <String>{
      ...await _d.allTaskIds(group: group),
      for (final record in records) record.taskId,
    };
    if (ids.isNotEmpty) await _d.cancelTasksWithIds(ids);
    await _d.database.deleteAllRecords(group: group);
  }

  @override
  void configureNotifications(String group, NotificationPlan plan) {
    _d.configureNotificationForGroup(
      group,
      running: plan.running,
      paused: plan.paused,
      complete: plan.complete,
      error: plan.error,
      progressBar: plan.running != null,
    );
  }

  @override
  Future<String> pathOf(bd.Task task) => task.filePath();
}

/// The `background_downloader` plugin as an [UploadTransport] (since 0.15.0), in this file because
/// it is the one that calls the plugin: the same rules, for the upload group. It never listens to
/// `FileDownloader().updates`, never calls a global (`start`, `reset`, `configure`,
/// `rescheduleKilledTasks`, which would send the app's own tracked tasks again) and never sets a
/// configuration the app did not. **No CI job runs it**; `docs/downloads.md` ("Uploads") lists
/// what only a device can show.
final class PluginUploadTransport implements UploadTransport {
  /// A transport over `FileDownloader()`, or over [downloader] (the plugin's scoped or test
  /// instance).
  PluginUploadTransport([bd.FileDownloader? downloader])
    : _downloader = downloader;

  bd.FileDownloader? _downloader;

  bd.FileDownloader get _d => _downloader ??= bd.FileDownloader();

  @override
  void register(
    String group, {
    required void Function(bd.TaskStatusUpdate update) onStatus,
    required void Function(bd.TaskProgressUpdate update) onProgress,
  }) {
    _d.registerCallbacks(
      group: group,
      taskStatusCallback: onStatus,
      taskProgressCallback: onProgress,
    );
  }

  @override
  void unregister(String group) {
    _d.unregisterCallbacks(group: group);
  }

  @override
  Future<void> track(String group) async {
    await _d.trackTasksInGroup(group);
  }

  @override
  Future<void> resumeFromBackground() => _d.resumeFromBackground();

  @override
  Future<List<bd.TaskRecord>> records(String group) async {
    await _d.ready;
    return _d.database.allRecords(group: group);
  }

  @override
  Future<Set<String>> activeIds(String group) async =>
      (await _d.allTaskIds(group: group)).toSet();

  @override
  Future<bd.UploadTask?> taskOf(String id) async {
    final task =
        (await _d.database.recordForId(id))?.task ?? await _d.taskForId(id);
    return task is bd.UploadTask ? task : null;
  }

  @override
  Future<bool> enqueue(bd.UploadTask task) => _d.enqueue(task);

  @override
  Future<void> cancel(String id) async {
    await _d.cancelTaskWithId(id);
    await _d.database.deleteRecordWithId(id);
  }

  @override
  Future<void> cancelAll(String group) async {
    await _d.ready;
    final records = await _d.database.allRecords(group: group);
    final ids = <String>{
      ...await _d.allTaskIds(group: group),
      for (final record in records) record.taskId,
    };
    if (ids.isNotEmpty) await _d.cancelTasksWithIds(ids);
    await _d.database.deleteAllRecords(group: group);
  }

  @override
  void configureNotifications(String group, NotificationPlan plan) {
    _d.configureNotificationForGroup(
      group,
      running: plan.running,
      paused: plan.paused,
      complete: plan.complete,
      error: plan.error,
      progressBar: plan.running != null,
    );
  }

  @override
  Future<String> pathOf(bd.Task task) => task.filePath();
}
