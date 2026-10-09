import 'package:background_downloader/background_downloader.dart' as bd;

import 'mapping.dart';

/// What the upload backend needs from `background_downloader` (since 0.15.0), as a port: the
/// plugin implements it (`PluginUploadTransport`, in the one file that calls the plugin) and a
/// test implements it with `FakeUploadTransport`. About **one group**, the backend's own; nothing
/// here reaches the app's tasks, its `updates` stream or the plugin's global state. There is no
/// pause or resume: the plugin's upload tasks cannot pause.
abstract interface class UploadTransport {
  /// Routes the updates of the tasks of [group] to the two callbacks. Called before
  /// [resumeFromBackground].
  void register(
    String group, {
    required void Function(bd.TaskStatusUpdate update) onStatus,
    required void Function(bd.TaskProgressUpdate update) onProgress,
  });

  /// Stops routing the updates of [group].
  void unregister(String group);

  /// Records the tasks of [group] in the plugin's database.
  Future<void> track(String group);

  /// Delivers what the operating system had for the app while it was away. **It is global in the
  /// plugin**: it delivers every group's updates, so the updates of a group with no callbacks yet
  /// go to the app's own stream.
  Future<void> resumeFromBackground();

  /// The plugin's records for [group].
  Future<List<bd.TaskRecord>> records(String group);

  /// The ids of the tasks of [group] that the operating system is running or has queued.
  Future<Set<String>> activeIds(String group);

  /// The upload task with this id, or null.
  Future<bd.UploadTask?> taskOf(String id);

  /// Queues [task]. False when the plugin refuses it.
  Future<bool> enqueue(bd.UploadTask task);

  /// Cancels the task [id] and forgets its record.
  Future<void> cancel(String id);

  /// Cancels every task of [group] and forgets its records.
  Future<void> cancelAll(String group);

  /// Sets the notifications of [group] to [plan]; an empty plan turns them off for the group.
  void configureNotifications(String group, NotificationPlan plan);

  /// The absolute path of [task]'s file, for the moment of use.
  Future<String> pathOf(bd.Task task);
}
