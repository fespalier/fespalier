import 'dart:async';

import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:fespalier_download/fespalier_download.dart';

import 'mapping.dart';
import 'platform.dart';
import 'plugin_transport.dart';
import 'transport.dart';

/// The background download backend (since 0.15.0): a [DownloadBackend] over
/// `background_downloader`, which hands the transfer to the operating system (WorkManager and
/// user-initiated data transfer jobs on Android, a background `URLSession` on iOS) so that it goes
/// on while the app is in the background and after it was closed.
///
/// **Honest capabilities.** On Android and iOS: pause, resume across a restart, background,
/// `userInitiated` and `unmetered`. `notifications` only when a [DownloadNotifications] with a
/// `running` text is configured (the constructor, or `configureNotifications`): the engine then
/// refuses a `userInitiated` request without one with `Failed(notificationsRequired)`, because
/// Android requires a visible notification for a user-initiated job. On the desktop it can pause
/// and nothing else (no operating-system background mode, no notification, no `unmetered`); on the
/// web every enqueued download ends `Failed(unsupported)` and the plugin is never touched.
///
/// **Only its own group.** Callbacks are registered for [BackgroundOptions.group] and for no
/// other; the app's `FileDownloader().updates` stream is never read and no global call
/// (`start`, `reset`, `configure`, `rescheduleKilledTasks`) is made. The plugin's own database is
/// not this package's registry: fespalier_download's `DownloadStore` is. Open the engine **before**
/// the app calls `FileDownloader().start()` or `resumeFromBackground()` itself, or what finished
/// while the app was away is delivered before this group has callbacks (UNCHECKED on a device,
/// see issue #158).
///
/// **The package never asks for the notification permission**: that is the app's, with a rationale
/// of its own. It starts no timer and listens to nothing.
///
/// **Headers persist.** The headers of a request, and the `authorization` of an attempt, are
/// written to the operating system's task queue in plaintext until the task ends, and a retry
/// sends the same ones. Give a short-lived grant (a URL or a download-scoped header), never a
/// refresh token or a long-lived bearer. A native callback cannot reach the app's state or its
/// plugins, so a proof per request (DPoP) is not possible here.
class BackgroundDownloaderBackend implements DownloadBackend {
  /// A backend. [notifications] are the texts of the notifications of its group (none by default:
  /// a download then shows nothing). [options] sets the retries and the group. [transport],
  /// [platform] and [files] are for tests; they default to the plugin, the platform this code runs
  /// on and `dart:io`.
  BackgroundDownloaderBackend({
    DownloadNotifications? notifications,
    this.options = const BackgroundOptions(),
    BackgroundTransport? transport,
    BackgroundPlatform? platform,
    TransferFiles? files,
  }) : _transport = transport ?? PluginTransport(),
       _platform = platform ?? BackgroundPlatform.current,
       _files = files ?? defaultTransferFiles() {
    _notifications = notifications;
  }

  /// The retries and the group.
  final BackgroundOptions options;

  final BackgroundTransport _transport;
  final BackgroundPlatform _platform;
  final TransferFiles _files;
  DownloadNotifications? _notifications;

  DownloadEvents? _events;
  final Map<String, bd.DownloadTask> _tasks = {};
  final Map<String, Progress> _progress = {};
  // Ids that reached an end state, until they are enqueued or resumed again: a late progress
  // update of a finished task is not reported.
  final Set<String> _ended = {};
  // Bumped by every enqueue, resume, cancel and close of an id and never reset, so that a check
  // that was waiting for a file cannot report over what came after it.
  final Map<String, int> _generations = {};
  // The attempts we cancelled: "<id>@<creation time in ms>". The plugin sends a `canceled` update
  // for a task we cancel, and for a retry or a renewed grant that update can arrive after the
  // same id was enqueued again: it must not end the new attempt. A task is told from its
  // successor by its creation time (kept to the millisecond, as the plugin stores it).
  final Set<String> _stale = {};
  // The checks of finished files that are still running; open() waits for them.
  final Set<Future<void>> _pending = {};

  bool get _hasRunning => _notifications?.running != null;

  @override
  DownloadCapabilities get capabilities => switch (_platform) {
    BackgroundPlatform.android ||
    BackgroundPlatform.ios => DownloadCapabilities(
      pause: true,
      resumeAcrossRestart: true,
      background: true,
      userInitiated: true,
      unmetered: true,
      notifications: _hasRunning,
    ),
    BackgroundPlatform.desktop => const DownloadCapabilities(pause: true),
    BackgroundPlatform.unsupported => const DownloadCapabilities(),
  };

  @override
  Future<void> open(DownloadEvents events) async {
    _events = events;
    if (_platform == BackgroundPlatform.unsupported) return;
    final group = options.group;
    _transport.configureNotifications(
      group,
      notificationPlanOf(_notifications),
    );
    // Callbacks first: everything below can deliver an update.
    _transport.register(
      group,
      onStatus: _onStatus,
      onProgress: _onProgress,
      onTap: _onTap,
    );
    await _replayRecords(group);
    await _transport.track(group);
    await _transport.resumeFromBackground();
    // A download that finished while the app was away is reported checked, before the engine
    // settles what the backend did not mention.
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  // What the plugin remembers of this group, reported as the engine's statuses. A task the
  // database calls enqueued or running that the operating system no longer has (the app was
  // killed, or the system dropped it) is not reported: the engine settles it from the file, as
  // Complete if it is there and as Failed(killed) if not. It is never enqueued again from here
  // (the plugin's own reschedule has no group and would also enqueue the app's tasks, and what
  // the task carries may be a grant that has expired): the app retries, with a fresh one.
  Future<void> _replayRecords(String group) async {
    final records = await _transport.records(group);
    final active = await _transport.activeIds(group);
    for (final record in records) {
      final task = record.task;
      if (task is! bd.DownloadTask || task.group != group) continue;
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
    DownloadRequest request, {
    Map<String, String> authorization = const {},
  }) async {
    final id = request.id;
    if (_events == null) return false;
    if (_platform == BackgroundPlatform.unsupported) {
      _report(id, const Failed(DownloadFailure.unsupported));
      return true;
    }
    if (!request.isValid || _destinationTaken(request)) {
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
    final task = downloadTaskOf(
      request,
      authorization: authorization,
      options: options,
    );
    _bump(id);
    _ended.remove(id);
    _progress.remove(id);
    _tasks[id] = task;
    final accepted = await _transport.enqueue(task);
    if (!accepted) _tasks.remove(id);
    return accepted;
  }

  // Two downloads must not write one file.
  bool _destinationTaken(DownloadRequest request) {
    final location = request.file;
    for (final entry in _tasks.entries) {
      if (entry.key != request.id && locationOf(entry.value) == location) {
        return true;
      }
    }
    return false;
  }

  Future<bd.DownloadTask?> _taskOf(String id) async {
    final known = _tasks[id];
    if (known != null) return known;
    final found = await _transport.taskOf(id);
    if (found != null) _tasks[id] = found;
    return found;
  }

  @override
  Future<bool> pause(String id) async {
    if (!capabilities.pause) return false;
    final task = await _taskOf(id);
    if (task == null) return false;
    return _transport.pause(task);
  }

  @override
  Future<bool> resume(
    String id, {
    Map<String, String> authorization = const {},
  }) async {
    if (!capabilities.pause) return false;
    final found = await _taskOf(id);
    if (found == null) return false;
    // A grant that expired while the download was paused is replaced here. Whether the plugin
    // sends the new headers on a resume from its stored data is UNCHECKED on a device (#158).
    final task = authorization.isEmpty
        ? found
        : found.copyWith(headers: {...found.headers, ...authorization});
    _bump(id);
    _ended.remove(id);
    _tasks[id] = task;
    return _transport.resume(task);
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
  Future<String> resolve(DownloadLocation location) async {
    if (_platform == BackgroundPlatform.unsupported) {
      throw UnsupportedError('no files on this platform');
    }
    return _transport.pathOf(pathProbeOf(location));
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

  void _onTap(bd.Task task, bd.NotificationType type) {
    _events?.tapped(task.taskId, DownloadTapKind.body);
  }

  void _onStatus(bd.TaskStatusUpdate update) => _dispatch(update);

  void _dispatch(bd.TaskStatusUpdate update) {
    if (_events == null) return;
    final task = update.task;
    final id = task.taskId;
    if (_isStale(task)) return;
    if (update.status == bd.TaskStatus.complete) {
      _ended.add(id);
      if (task is bd.DownloadTask) _tasks[id] = task;
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

  // The plugin says the file is there. Check it against the size and the digest the request
  // carried (in the task, so a download that finished while the app was away is checked now),
  // then report. The engine does not check files: this backend does, as the foreground one does.
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
    final expectation = TaskExpectation.decode(task.metaData);
    try {
      if (!_files.isSupported) {
        _report(id, Complete(location, expectation.bytes ?? 0));
        return;
      }
      final path = await _transport.pathOf(task);
      if (!current()) return;
      if (!expectation.isEmpty) _report(id, const Verifying());
      final length = await _files.length(path);
      if (!current()) return;
      if (length == null) {
        _report(id, const Failed(DownloadFailure.storage));
        return;
      }
      final wanted = expectation.bytes;
      if (wanted != null && wanted != length) {
        _report(id, const Failed(DownloadFailure.sizeMismatch));
        return;
      }
      final digest = expectation.sha256;
      if (digest != null) {
        final actual = await _files.sha256(path);
        if (!current()) return;
        if (actual.toLowerCase() != digest.toLowerCase()) {
          _report(id, const Failed(DownloadFailure.hashMismatch));
          return;
        }
      }
      _report(id, Complete(location, length));
    } catch (_) {
      // Nothing of the error is kept: it can name a path.
      if (current()) _report(id, const Failed(DownloadFailure.storage));
    }
  }
}
