import 'dart:async';

import 'package:fespalier/fespalier.dart'
    show
        Notifier,
        NotifierProvider,
        Provider,
        RefetchSignal,
        appResumeSignal,
        reconnectSignal;

import 'sync_engine.dart';

/// The periodic trigger: a `RefetchSignal` that never fires by itself (like core's
/// `reconnectSignal`). The app overrides it with a ticker of its own: its timer, its choice of
/// period, owned and tested in the app (the README has the recipe). This package starts no timer.
final syncTicker = NotifierProvider.autoDispose<RefetchSignal, int>(
  RefetchSignal.new,
);

/// Which triggers `autoSync` follows. Resume needs a `WidgetsBinding`: a bare container test turns
/// it off.
final class SyncTriggers {
  /// All on, or the ones given.
  const SyncTriggers({
    this.onStart = true,
    this.onResume = true,
    this.onReconnect = true,
    this.onTick = true,
  });

  /// Sync when `autoSync` starts.
  final bool onStart;

  /// Sync when the app comes back to the foreground (core's `appResumeSignal`).
  final bool onResume;

  /// Sync when the network comes back (core's `reconnectSignal`).
  final bool onReconnect;

  /// Sync when [syncTicker] fires.
  final bool onTick;
}

/// The triggers `autoSync` follows.
final syncTriggers = Provider<SyncTriggers>((ref) => const SyncTriggers());

/// What `autoSync` holds: whether a sync is running and what the last one did.
final class SyncStatus {
  /// A status.
  const SyncStatus({this.isSyncing = false, this.last});

  /// Whether a sync started by a trigger is running: for a banner.
  final bool isSyncing;

  /// The last report, or null before the first sync finished.
  final SyncReport? last;
}

/// The notifier of [autoSync].
class AutoSync extends Notifier<SyncStatus> {
  int? _resume;
  int? _reconnect;
  int? _tick;
  var _started = false;
  var _running = 0;
  SyncReport? _last;

  @override
  SyncStatus build() {
    final triggers = ref.watch(syncTriggers);
    final runner = ref.watch(syncRunner);
    // The signals are watched, not listened to: a change rebuilds this notifier, and the counts
    // kept in the fields tell which one moved.
    SyncReason? reason;
    if (triggers.onResume) {
      final count = ref.watch(appResumeSignal);
      if (_resume != null && count != _resume) reason = SyncReason.resume;
      _resume = count;
    }
    if (triggers.onReconnect) {
      final count = ref.watch(reconnectSignal);
      if (_reconnect != null && count != _reconnect) {
        reason = SyncReason.reconnect;
      }
      _reconnect = count;
    }
    if (triggers.onTick) {
      final count = ref.watch(syncTicker);
      if (_tick != null && count != _tick) reason = SyncReason.tick;
      _tick = count;
    }
    if (!_started) {
      _started = true;
      if (triggers.onStart) reason = SyncReason.start;
    }
    if (reason != null) _start(runner, reason);
    return SyncStatus(isSyncing: _running > 0, last: _last);
  }

  /// A side `then`, not a call from `build`: a sync bumps other providers, which Riverpod forbids
  /// while one is building.
  void _start(SyncRunner runner, SyncReason reason) {
    _running++;
    unawaited(
      Future<void>.value()
          .then<SyncReport?>((_) => ref.mounted ? runner.sync(reason) : null)
          .then<void>(
            (report) => _finish(report),
            onError: (Object _, StackTrace _) => _finish(null),
          ),
    );
  }

  void _finish(SyncReport? report) {
    _running--;
    if (!ref.mounted) return;
    // A sync that was skipped (too recent) did nothing: the banner keeps the last real result.
    if (report != null && !report.skipped) _last = report;
    state = SyncStatus(isSyncing: _running > 0, last: _last);
  }
}

/// Runs [syncRunner] on start and whenever core's `appResumeSignal`, `reconnectSignal` or
/// [syncTicker] changes.
///
/// It watches them (no listener: it rebuilds), tells which one moved by comparing counts it kept,
/// and starts the sync with a side `then`. Its state is the last report, and `isSyncing` for a
/// banner. It lives while watched: the app watches it once, in the root `layout.dart`. It starts no
/// timer, listens to nothing and never retries (the provider sets `retry` to null, because
/// Riverpod's own retry waits on a timer).
final autoSync = NotifierProvider.autoDispose<AutoSync, SyncStatus>(
  AutoSync.new,
  retry: (_, _) => null,
);
