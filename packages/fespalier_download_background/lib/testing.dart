/// Fakes for testing the background backend with no plugin and no device (since 0.15.0):
/// `FakeBackgroundTransport` plays `background_downloader` for one group, and the test plays the
/// operating system through `emitStatus`, `emitProgress` and `tap`.
///
/// **The plugin itself is not exercised by any test here**: there is no device in CI, so the
/// forwarding layer (`PluginTransport`) and everything an operating system decides are listed as
/// unchecked in `docs/downloads.md`.
library;

import 'package:background_downloader/background_downloader.dart' as bd;

import 'src/mapping.dart';
import 'src/transport.dart';

/// A [BackgroundTransport] that does nothing by itself (since 0.15.0).
///
/// Like the plugin, it routes an update to the callbacks of the **group** of its task, and an
/// update of a group with no callbacks goes to [leaked] (what would reach the app's own `updates`
/// stream). [calls] records the order of the calls, to check that callbacks are registered before
/// `resumeFromBackground`.
class FakeBackgroundTransport implements BackgroundTransport {
  /// A fake. [accepts] decides whether [enqueue] succeeds; [records] and [active] are what the
  /// plugin remembers and runs at the start; [undelivered] are delivered to the callbacks by
  /// [resumeFromBackground], as the updates that came while the app was away.
  FakeBackgroundTransport({
    this.accepts = true,
    List<bd.TaskRecord> records = const [],
    Set<String> active = const {},
    List<bd.TaskStatusUpdate> undelivered = const [],
  }) : _records = [...records],
       active = {...active},
       undelivered = [...undelivered];

  /// Whether [enqueue] answers true.
  bool accepts;

  /// Whether [pause] answers true.
  bool pauseAccepts = true;

  /// Whether [resume] answers true.
  bool resumeAccepts = true;

  final List<bd.TaskRecord> _records;

  /// What [activeIds] answers.
  final Set<String> active;

  /// Delivered by [resumeFromBackground].
  final List<bd.TaskStatusUpdate> undelivered;

  /// The folder [pathOf] puts everything under.
  String root = '/fake';

  /// The name of every call, in order, with its group where it has one: `register:g`,
  /// `track:g`, `resumeFromBackground`, `enqueue:<id>`, and so on.
  final List<String> calls = [];

  /// Every task handed to [enqueue], in order.
  final List<bd.DownloadTask> enqueued = [];

  /// Every task handed to [pause], in order.
  final List<bd.DownloadTask> paused = [];

  /// Every task handed to [resume], in order.
  final List<bd.DownloadTask> resumed = [];

  /// Every id handed to [cancel], in order.
  final List<String> cancelled = [];

  /// Every group handed to [cancelAll], in order.
  final List<String> cancelledGroups = [];

  /// The groups with callbacks registered right now.
  final Set<String> registered = {};

  /// The plan most recently handed to [configureNotifications], by group.
  final Map<String, NotificationPlan> plans = {};

  /// The status updates that reached no callback: a group with none registered.
  final List<bd.TaskStatusUpdate> leaked = [];

  /// The progress updates that reached no callback.
  final List<bd.TaskProgressUpdate> leakedProgress = [];

  final Map<String, void Function(bd.TaskStatusUpdate)> _status = {};
  final Map<String, void Function(bd.TaskProgressUpdate)> _progress = {};
  final Map<String, void Function(bd.Task, bd.NotificationType)> _tap = {};
  final Map<String, bd.DownloadTask> _known = {};

  /// Makes [task] findable by [taskOf], as the plugin would after a restart.
  void know(bd.DownloadTask task) => _known[task.taskId] = task;

  /// Delivers [update] as the operating system would.
  void emitStatus(bd.TaskStatusUpdate update) {
    final callback = _status[update.task.group];
    if (callback == null) {
      leaked.add(update);
      return;
    }
    callback(update);
  }

  /// Delivers [update] as the operating system would.
  void emitProgress(bd.TaskProgressUpdate update) {
    final callback = _progress[update.task.group];
    if (callback == null) {
      leakedProgress.add(update);
      return;
    }
    callback(update);
  }

  /// Delivers a tap on a notification of [task].
  void tap(
    bd.Task task, [
    bd.NotificationType type = bd.NotificationType.running,
  ]) => _tap[task.group]?.call(task, type);

  @override
  void register(
    String group, {
    required void Function(bd.TaskStatusUpdate update) onStatus,
    required void Function(bd.TaskProgressUpdate update) onProgress,
    required void Function(bd.Task task, bd.NotificationType type) onTap,
  }) {
    calls.add('register:$group');
    registered.add(group);
    _status[group] = onStatus;
    _progress[group] = onProgress;
    _tap[group] = onTap;
  }

  @override
  void unregister(String group) {
    calls.add('unregister:$group');
    registered.remove(group);
    _status.remove(group);
    _progress.remove(group);
    _tap.remove(group);
  }

  @override
  Future<void> track(String group) async {
    calls.add('track:$group');
  }

  @override
  Future<void> resumeFromBackground() async {
    calls.add('resumeFromBackground');
    for (final update in [...undelivered]) {
      emitStatus(update);
    }
    undelivered.clear();
  }

  @override
  Future<List<bd.TaskRecord>> records(String group) async {
    calls.add('records:$group');
    return [
      for (final record in _records)
        if (record.group == group) record,
    ];
  }

  @override
  Future<Set<String>> activeIds(String group) async => {...active};

  @override
  Future<bd.DownloadTask?> taskOf(String id) async => _known[id];

  @override
  Future<bool> enqueue(bd.DownloadTask task) async {
    calls.add('enqueue:${task.taskId}');
    enqueued.add(task);
    if (accepts) _known[task.taskId] = task;
    return accepts;
  }

  @override
  Future<bool> pause(bd.DownloadTask task) async {
    calls.add('pause:${task.taskId}');
    paused.add(task);
    return pauseAccepts;
  }

  @override
  Future<bool> resume(bd.DownloadTask task) async {
    calls.add('resume:${task.taskId}');
    resumed.add(task);
    return resumeAccepts;
  }

  @override
  Future<void> cancel(String id) async {
    calls.add('cancel:$id');
    cancelled.add(id);
    _known.remove(id);
  }

  @override
  Future<void> cancelAll(String group) async {
    calls.add('cancelAll:$group');
    cancelledGroups.add(group);
    _known.clear();
  }

  @override
  void configureNotifications(String group, NotificationPlan plan) {
    calls.add('notifications:$group');
    plans[group] = plan;
  }

  @override
  Future<String> pathOf(bd.Task task) async {
    final location = locationOf(task);
    return '$root/${location?.base.name ?? 'other'}/${location?.path ?? task.filename}';
  }
}
