import 'package:background_downloader/background_downloader.dart' as bd;

import 'mapping.dart';

/// What the backend needs from `background_downloader` (since 0.15.0), as a port: the plugin
/// implements it (`PluginTransport`, the one file that calls the plugin) and a test implements it
/// with `FakeBackgroundTransport`, so the backend's logic runs without a device.
///
/// Every method is about **one group**, the backend's own. Nothing here reaches the app's tasks,
/// its `updates` stream or the plugin's global state.
abstract interface class BackgroundTransport {
  /// Routes the updates of the tasks of [group] to the three callbacks. Called before
  /// [resumeFromBackground], so nothing that finished while the app was away is lost.
  void register(
    String group, {
    required void Function(bd.TaskStatusUpdate update) onStatus,
    required void Function(bd.TaskProgressUpdate update) onProgress,
    required void Function(bd.Task task, bd.NotificationType type) onTap,
  });

  /// Stops routing the updates of [group].
  void unregister(String group);

  /// Records the tasks of [group] in the plugin's database, and reports the ones whose file is
  /// already there as complete.
  Future<void> track(String group);

  /// Delivers what the operating system had for the app while it was away.
  Future<void> resumeFromBackground();

  /// The plugin's records for [group]: what the plugin remembers of each task.
  Future<List<bd.TaskRecord>> records(String group);

  /// The ids of the tasks of [group] that the operating system is running or has queued.
  Future<Set<String>> activeIds(String group);

  /// The task with this id, or null.
  Future<bd.DownloadTask?> taskOf(String id);

  /// Queues [task]. False when the plugin refuses it.
  Future<bool> enqueue(bd.DownloadTask task);

  /// Pauses [task]. False when it cannot be paused.
  Future<bool> pause(bd.DownloadTask task);

  /// Resumes [task] (a paused one, with the headers it carries). False when there is nothing to
  /// resume from.
  Future<bool> resume(bd.DownloadTask task);

  /// Cancels the task [id], paused ones included, and forgets its record.
  Future<void> cancel(String id);

  /// Cancels every task of [group] and forgets its records.
  Future<void> cancelAll(String group);

  /// Sets the notifications of [group] to [plan]; an empty plan turns them off for the group
  /// (and so also hides the app's own default from it).
  void configureNotifications(String group, NotificationPlan plan);

  /// The absolute path the plugin puts [task]'s file at, for the moment of use. [task] may be a
  /// probe that only names a location (never enqueued).
  Future<String> pathOf(bd.Task task);
}
