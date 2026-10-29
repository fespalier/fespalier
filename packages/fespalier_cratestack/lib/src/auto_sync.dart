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

/// The push trigger (since 0.25.0): a count that moves when the server says something changed. It
/// is 0 and never moves until the app overrides it with what it hears from its server, usually a
/// change feed over a CrateStack subscription:
///
/// ```dart
/// final serverChanges = ChangeFeed<CrateStackModelEvent>.live(
///   (ref, _) => crateStackEvents(ref.watch(apiTransport), apiBase, 'model.Note.subscribe'),
///   rules: LiveRules(reconnectOn: [reconnectSignal, appShowSignal]),
/// );
/// // in startup():
/// syncPushSignal.overrideWith((ref) => ref.watch(serverChanges.any)),
/// ```
///
/// `autoSync` watches it like its other signals (no listener) and runs a [SyncReason.push] each
/// time the count changes. An event is only a hint that something changed: the sync reads the
/// rows through the app's API, never from the event. A signal that throws is ignored, and a feed
/// that was refused moves nothing (its `latest` holds the error): the other triggers keep working.
final syncPushSignal = Provider<int>((ref) => 0, name: 'syncPushSignal');

/// Which triggers `autoSync` follows. Resume needs a `WidgetsBinding`: a bare container test turns
/// it off.
final class SyncTriggers {
  /// All on, or the ones given.
  const SyncTriggers({
    this.onStart = true,
    this.onResume = true,
    this.onReconnect = true,
    this.onTick = true,
    this.onPush = true,
  });

  /// Sync when `autoSync` starts.
  final bool onStart;

  /// Sync when the app comes back to the foreground (core's `appResumeSignal`).
  final bool onResume;

  /// Sync when the network comes back (core's `reconnectSignal`).
  final bool onReconnect;

  /// Sync when [syncTicker] fires.
  final bool onTick;

  /// Sync when [syncPushSignal] moves (since 0.25.0). It does nothing until the app overrides
  /// that signal.
  final bool onPush;
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
  int? _push;
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
    if (triggers.onPush) {
      // Last, so that it wins over resume, reconnect and tick when two moved at once: a push
      // skips the minimum interval, which would skip the others.
      int? count;
      try {
        count = ref.watch(syncPushSignal);
      } on Object {
        // A signal that throws (an override with a bug): the other triggers keep working, and the
        // count kept stays, so the next value is compared with the last good one.
        count = null;
      }
      if (count != null) {
        if (_push != null && count != _push) reason = SyncReason.push;
        _push = count;
      }
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

/// Runs [syncRunner] on start and whenever core's `appResumeSignal`, `reconnectSignal`,
/// [syncTicker] or (since 0.25.0) [syncPushSignal] changes.
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
