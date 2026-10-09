import 'dart:async';

import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:fespalier_download/fespalier_download.dart';

import 'mapping.dart';
import 'platform.dart';
import 'plugin_transport.dart';
import 'upload_mapping.dart';
import 'upload_ports.dart';
import 'upload_request.dart';
import 'upload_transport.dart';

/// The background upload backend (since 0.15.0): an [UploadBackend] over `background_downloader`
/// 9.6.4's `UploadTask`, which hands the transfer to the operating system (WorkManager and
/// user-initiated data transfer jobs on Android, a background `URLSession` on iOS).
///
/// **Honest capabilities.** On Android and iOS: background, `userInitiated`, `unmetered`, and
/// `notifications` only when a [DownloadNotifications] with a `running` text is configured. **No
/// pause**: the plugin cannot pause an upload. On the desktop nothing (no operating-system
/// background mode, no notification, no `unmetered`); on the web every enqueue ends
/// `Failed(unsupported)` and the plugin is never touched.
///
/// **Its own group** (`backgroundUploadGroup`), so its updates never reach the downloads' callbacks
/// or the app's `FileDownloader().updates`, and no global call is made. The plugin's database is
/// not the registry: `UploadStore` is.
///
/// **Retries only when replay safe**: the task gets [BackgroundOptions.retries] if the request
/// carries an `Idempotency-Key`, and 0 otherwise. A kill is never answered by sending the upload
/// again: the engine ends it `Failed(killed)`.
///
/// **Headers persist.** A request's headers, and an attempt's `authorization`, are written to the
/// operating system's task queue in plaintext until the task ends, and a retry sends the same ones.
/// Give a short-lived grant, never a refresh token or a long-lived bearer.
///
/// **UNCHECKED on a device** (`docs/downloads.md`, "Uploads"): that the operating system sends the
/// task at all, how a server reads the multipart body the plugin writes, how long an upload may
/// run on Android before WorkManager's limit ends it, and what is delivered when the app opens
/// the uploads and downloads engines one after the other.
class BackgroundUploaderBackend implements UploadBackend {
  /// A backend. [notifications] are the texts of the notifications of its group (none by
  /// default). [options] sets the retries of a replay-safe upload and the group. [transport],
  /// [platform] and [files] are for tests; they default to the plugin, the platform this code runs
  /// on and `dart:io`.
  BackgroundUploaderBackend({
    DownloadNotifications? notifications,
    this.options = defaultUploadOptions,
    UploadTransport? transport,
    BackgroundPlatform? platform,
    TransferFiles? files,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _transport = transport ?? PluginUploadTransport(),
       _platform = platform ?? BackgroundPlatform.current,
       _files = files ?? defaultTransferFiles() {
    _notifications = notifications;
  }

  /// The retries of a replay-safe upload and the group.
  final BackgroundOptions options;

  final DateTime Function() _now;
  final UploadTransport _transport;
  final BackgroundPlatform _platform;
  final TransferFiles _files;
  DownloadNotifications? _notifications;

  UploadEvents? _events;
  final Map<String, bd.UploadTask> _tasks = {};
  final Map<String, Progress> _progress = {};
  final Set<String> _ended = {};
  // Bumped by every enqueue, cancel and close of an id and never reset, so that a size check
  // that was waiting for a file cannot report over what came after it.
  final Map<String, int> _generations = {};
  // The attempts we cancelled ("<id>@<creation ms>"): the plugin sends `canceled` for them, and
  // that must not end a renewed attempt of the same id.
  final Set<String> _stale = {};
  // The creation time (ms) of the latest attempt of an id, strictly increasing per id.
  final Map<String, int> _lastCreation = {};
  final Set<Future<void>> _pending = {};

  bool get _hasRunning => _notifications?.running != null;

  @override
  DownloadCapabilities get capabilities => switch (_platform) {
    BackgroundPlatform.android ||
    BackgroundPlatform.ios => DownloadCapabilities(
      background: true,
      userInitiated: true,
      unmetered: true,
      notifications: _hasRunning,
    ),
    BackgroundPlatform.desktop ||
    BackgroundPlatform.unsupported => const DownloadCapabilities(),
  };

  @override
  Future<void> open(UploadEvents events) async {
    _events = events;
    if (_platform == BackgroundPlatform.unsupported) return;
    final group = options.group;
    _transport.configureNotifications(
      group,
      notificationPlanOf(_notifications),
    );
    // Callbacks first: everything below can deliver an update.
    _transport.register(group, onStatus: _dispatch, onProgress: _onProgress);
    await _replayRecords(group);
    await _transport.track(group);
    await _transport.resumeFromBackground();
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  // What the plugin remembers of this group. A task the database calls enqueued or running that
  // the operating system no longer has is not reported: the engine ends it Failed(killed). It is
  // never enqueued again from here.
  Future<void> _replayRecords(String group) async {
    final records = await _transport.records(group);
    final active = await _transport.activeIds(group);
    for (final record in records) {
      final task = record.task;
      if (task is! bd.UploadTask || task.group != group) continue;
      final id = task.taskId;
      _tasks[id] = task;
      final stale =
          (record.status == bd.TaskStatus.enqueued ||
              record.status == bd.TaskStatus.running) &&
          !active.contains(id);
      if (stale) continue;
      final progress = progressOf(record.progress, record.expectedFileSize);
      if (progress != null) _progress[id] = progress;
      _dispatch(bd.TaskStatusUpdate(task, record.status, record.exception));
    }
  }

  @override
  Future<void> close() async {
    final events = _events;
    _events = null;
    if (events == null) return;
    if (_platform != BackgroundPlatform.unsupported) {
      _transport.unregister(options.group);
    }
    _tasks.clear();
    _stale.clear();
    _progress.clear();
    _ended.clear();
    for (final id in _generations.keys.toList()) {
      _bump(id);
    }
  }

  static String _key(bd.Task task) =>
      '${task.taskId}@${task.creationTime.millisecondsSinceEpoch}';

  bool _isStale(bd.Task task) => _stale.contains(_key(task));

  int _generationOf(String id) => _generations[id] ?? 0;

  int _bump(String id) => _generations[id] = _generationOf(id) + 1;

  void _report(String id, DownloadStatus status, {int? httpStatus}) {
    _events?.status(id, status, httpStatus: httpStatus);
  }

  @override
  Future<bool> enqueue(
    UploadRequest request, {
    Map<String, String> authorization = const {},
  }) async {
    final id = request.id;
    if (_events == null) return false;
    if (_platform == BackgroundPlatform.unsupported) {
      _report(id, const Failed(DownloadFailure.unsupported));
      return true;
    }
    if (!request.isValid) {
      _report(id, const Failed(DownloadFailure.invalidRequest));
      return true;
    }
    if (request.priority == DownloadPriority.userInitiated &&
        !capabilities.notifications) {
      _report(id, const Failed(DownloadFailure.notificationsRequired));
      return true;
    }
    // The desktop cannot tell a metered network from another: refuse rather than spend data the
    // app said not to.
    if (request.network == DownloadNetwork.unmetered &&
        !capabilities.unmetered) {
      return false;
    }
    final nowMs = _now().millisecondsSinceEpoch;
    final previous = _lastCreation[id];
    final created = previous != null && nowMs <= previous
        ? previous + 1
        : nowMs;
    _lastCreation[id] = created;
    final task = uploadTaskOf(
      request,
      authorization: authorization,
      options: options,
      creationTime: DateTime.fromMillisecondsSinceEpoch(created),
    );
    _bump(id);
    _ended.remove(id);
    _progress.remove(id);
    _tasks[id] = task;
    final accepted = await _transport.enqueue(task);
    if (!accepted) _tasks.remove(id);
    return accepted;
  }

  @override
  Future<void> cancel(String id) async {
    _bump(id);
    final known =
        _tasks.remove(id) ??
        (_platform == BackgroundPlatform.unsupported
            ? null
            : await _transport.taskOf(id));
    if (known != null) _stale.add(_key(known));
    _progress.remove(id);
    _ended.remove(id);
    if (_platform == BackgroundPlatform.unsupported) return;
    await _transport.cancel(id);
  }

  @override
  Future<void> cancelAll() async {
    for (final id in {..._tasks.keys, ..._generations.keys}) {
      _bump(id);
    }
    _stale.addAll(_tasks.values.map(_key));
    _tasks.clear();
    _progress.clear();
    _ended.clear();
    if (_platform == BackgroundPlatform.unsupported) return;
    await _transport.cancelAll(options.group);
  }

  @override
  Future<void> configureNotifications(
    DownloadNotifications? notifications,
  ) async {
    _notifications = notifications;
    if (_events != null && _platform != BackgroundPlatform.unsupported) {
      _transport.configureNotifications(
        options.group,
        notificationPlanOf(notifications),
      );
    }
  }

  void _onProgress(bd.TaskProgressUpdate update) {
    final id = update.task.taskId;
    if (_events == null || _ended.contains(id) || _isStale(update.task)) return;
    final progress = progressOfUpdate(update);
    if (progress == null) return;
    _progress[id] = progress;
    _report(id, Running(progress.received, progress.total));
  }

  void _dispatch(bd.TaskStatusUpdate update) {
    if (_events == null) return;
    final task = update.task;
    final id = task.taskId;
    if (_isStale(task)) return;
    if (update.status == bd.TaskStatus.complete) {
      _ended.add(id);
      if (task is bd.UploadTask) _tasks[id] = task;
      final check = _complete(update);
      _pending.add(check);
      unawaited(check.whenComplete(() => _pending.remove(check)));
      return;
    }
    final mapped = downloadStatusOf(
      update,
      known: _progress[id] ?? Progress.none,
    );
    if (mapped == null) return;
    final status = mapped.status;
    if (status is Failed || status is Cancelled) _ended.add(id);
    _report(id, status, httpStatus: mapped.httpStatus);
  }

  // The server took it. The size reported is the file's, read now (best effort: 0 when it cannot
  // be read, which is no reason to doubt the server's answer). The file is never touched.
  Future<void> _complete(bd.TaskStatusUpdate update) async {
    final task = update.task;
    final id = task.taskId;
    final generation = _generationOf(id);
    bool current() => _events != null && generation == _generationOf(id);
    final location = locationOf(task);
    if (location == null) {
      _report(id, const Failed(DownloadFailure.other));
      return;
    }
    var length = 0;
    try {
      if (_files.isSupported) {
        length = await _files.length(await _transport.pathOf(task)) ?? 0;
      }
    } catch (_) {
      // Nothing of the error is kept: it can name a path.
    }
    if (current()) _report(id, Complete(location, length));
  }
}
