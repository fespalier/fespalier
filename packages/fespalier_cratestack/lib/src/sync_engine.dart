import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:fespalier/fespalier.dart' show Provider;

import 'errors.dart';
import 'intent.dart';
import 'intent_queue.dart';
import 'owned_rows.dart';
import 'revision.dart';
import 'row_sync.dart';

/// Why a sync ran (reported, and used for the minimum interval).
enum SyncReason {
  /// The app started (the root layout began to watch `autoSync`).
  start,

  /// The app came back to the foreground.
  resume,

  /// The device went from no network to a network.
  reconnect,

  /// The app's periodic ticker fired.
  tick,

  /// A person or an action asked for it.
  manual,
}

/// A row that was rolled back to the server's version (or dropped) because the server refused it.
final class RolledBack {
  /// A rolled-back row.
  const RolledBack({
    required this.collection,
    required this.id,
    required this.code,
  });

  /// The row's collection.
  final String collection;

  /// The row's id.
  final String id;

  /// The wire code of the refusal. The server's message is never kept.
  final String code;
}

/// What a sync did.
final class SyncReport {
  /// A report.
  const SyncReport({
    required this.reason,
    this.reachedServer = false,
    this.pushed = 0,
    this.pulled = 0,
    this.rolledBack = const [],
    this.intents = const DrainReport(),
    this.failure,
    this.skipped = false,
  });

  /// A sync that did nothing because the last one was too recent.
  const SyncReport.skipped(this.reason)
    : reachedServer = false,
      pushed = 0,
      pulled = 0,
      rolledBack = const [],
      intents = const DrainReport(),
      failure = null,
      skipped = true;

  /// Why it ran.
  final SyncReason reason;

  /// Whether CrateStack answered anything.
  final bool reachedServer;

  /// How many rows the server took.
  final int pushed;

  /// How many rows came back.
  final int pulled;

  /// The rows the server refused.
  final List<RolledBack> rolledBack;

  /// What the drain of the intent queue did.
  final DrainReport intents;

  /// The first failure, if any. A sync never throws: this says what failed.
  final CrateStackFailure? failure;

  /// Whether it did nothing because of the minimum interval.
  final bool skipped;
}

/// What runs a sync: [SyncEngine], or an app's own (e.g. a Rust core with its own engine behind
/// flutter_rust_bridge).
abstract interface class SyncRunner {
  /// Runs a sync and says what happened. It must not throw.
  Future<SyncReport> sync(SyncReason reason);
}

/// Push the dirty owned rows, pull each collection, then drain the intents, in that order: an
/// intent may name a row made offline, and the server must have it first. The drain runs even if
/// the push failed, and stops at the first sign of no network.
final class SyncEngine implements SyncRunner {
  /// An engine over [rows] and [intents]; [rowSync] is null for an app with intents only.
  SyncEngine({
    required OwnedRows rows,
    RowSync? rowSync,
    required IntentQueue intents,
    required List<String> collections,
    required BumpTags bump,
    this.minInterval = const Duration(seconds: 10),
    CrateStackErrors errors = const CrateStackErrors([]),
  }) : _rows = rows,
       _rowSync = rowSync,
       _intents = intents,
       _collections = collections,
       _bump = bump,
       _errors = errors;

  final OwnedRows _rows;
  final RowSync? _rowSync;
  final IntentQueue _intents;
  final List<String> _collections;
  final BumpTags _bump;
  final CrateStackErrors _errors;

  /// A sync caused by a signal (resume, reconnect, tick) within this long of the last one that
  /// reached the server does nothing. `start` and `manual` always run.
  final Duration minInterval;

  Future<SyncReport>? _running;
  DateTime? _lastReached;

  /// Single-flight: a call while one runs joins it (the same `Future`). Never throws: the report
  /// says what failed.
  @override
  Future<SyncReport> sync(SyncReason reason) {
    final running = _running;
    if (running != null) return running;
    final bySignal =
        reason == SyncReason.resume ||
        reason == SyncReason.reconnect ||
        reason == SyncReason.tick;
    final last = _lastReached;
    if (bySignal &&
        last != null &&
        clock.now().difference(last) < minInterval) {
      return Future.value(SyncReport.skipped(reason));
    }
    final run = _run(reason);
    _running = run;
    run.then<void>((_) {
      if (identical(_running, run)) _running = null;
    });
    return run;
  }

  CrateStackFailure _failureOf(Object error) {
    final failure = _errors.classify(error);
    if (failure != null) return failure;
    if (kDebugMode) {
      debugPrint(
        'fespalier_cratestack: a sync failed with an error no reader knows: ${error.runtimeType}',
      );
    }
    return const CrateStackUnavailable(status: 0, code: 'unknown');
  }

  Future<SyncReport> _run(SyncReason reason) async {
    final changed = <String>{};
    final rolledBack = <RolledBack>[];
    var pushed = 0;
    var pulled = 0;
    var reached = false;
    var offline = false;
    CrateStackFailure? failure;
    final rowSync = _rowSync;
    if (rowSync != null && _collections.isNotEmpty) {
      try {
        final dirty = await _rows.dirty(_collections);
        if (dirty.isNotEmpty) {
          final result = await rowSync.push(dirty);
          reached = true;
          pushed = await _apply(result, rolledBack, changed);
        }
      } on Object catch (error) {
        failure = _failureOf(error);
        offline = failure is CrateStackOffline;
      }
      if (!offline) {
        try {
          for (final collection in _collections) {
            pulled += await _pull(rowSync, collection, changed);
            reached = true;
          }
        } on Object catch (error) {
          failure ??= _failureOf(error);
          offline = failure is CrateStackOffline;
        }
      }
    }
    var intents = const DrainReport();
    try {
      intents = await _intents.drain();
      reached = reached || intents.reachedServer;
    } on Object catch (error) {
      failure ??= _failureOf(error);
    }
    if (intents.offline) failure ??= const CrateStackOffline();
    if (changed.isNotEmpty) _bump(changed);
    if (reached) _lastReached = clock.now();
    return SyncReport(
      reason: reason,
      reachedServer: reached,
      pushed: pushed,
      pulled: pulled,
      rolledBack: rolledBack,
      intents: intents,
      failure: failure,
    );
  }

  Future<int> _apply(
    PushResult result,
    List<RolledBack> rolledBack,
    Set<String> changed,
  ) async {
    await _rows.adopt(result.accepted);
    for (final row in result.accepted) {
      changed.add(row.collection);
    }
    for (final rejection in result.rejected) {
      // Back to the server's version, or gone: the local edit is undone, and said to be.
      await _rows.discard(rejection.collection, rejection.id);
      final server = rejection.server;
      if (server != null) await _rows.adopt([server]);
      changed.add(rejection.collection);
      rolledBack.add(
        RolledBack(
          collection: rejection.collection,
          id: rejection.id,
          code: rejection.code,
        ),
      );
    }
    return result.accepted.length;
  }

  Future<int> _pull(
    RowSync rowSync,
    String collection,
    Set<String> changed,
  ) async {
    var cursor = await _rows.cursor(collection);
    var count = 0;
    while (true) {
      final page = await rowSync.pull(collection, cursor);
      if (page.rows.isNotEmpty) {
        count += await _rows.adopt(page.rows);
        changed.add(collection);
      }
      final next = page.nextCursor;
      if (next != null) await _rows.setCursor(collection, next);
      // A server that says "more" and gives the same cursor would otherwise be asked forever.
      if (!page.hasMore || next == null || next == cursor) return count;
      cursor = next;
    }
  }

  /// Push only, awaited: for an action that needs its rows on the server before the server
  /// decides (a checkout that names a row made offline). Unlike [sync] it throws: a
  /// `CrateStackOffline` is the honest answer to "are they there?". Waits for a running sync first.
  Future<PushResult> push() async {
    final running = _running;
    if (running != null) await running;
    final rowSync = _rowSync;
    if (rowSync == null || _collections.isEmpty) return const PushResult();
    final dirty = await _rows.dirty(_collections);
    if (dirty.isEmpty) return const PushResult();
    final PushResult result;
    try {
      result = await rowSync.push(dirty);
    } on Object catch (error, stackTrace) {
      final failure = _errors.classify(error);
      if (failure == null) rethrow;
      Error.throwWithStackTrace(failure, stackTrace);
    }
    final changed = <String>{};
    await _apply(result, [], changed);
    _lastReached = clock.now();
    if (changed.isNotEmpty) _bump(changed);
    return result;
  }
}

/// The engine of the current account: owned rows, the app's [rowSync] and the intent queue.
final syncEngine = Provider<SyncEngine>(
  (ref) => SyncEngine(
    rows: ref.watch(ownedRows),
    rowSync: ref.watch(rowSync),
    intents: ref.watch(intentQueue),
    collections: ref.watch(syncCollections),
    bump: ref.watch(crateStackBump),
    errors: ref.watch(crateStackErrors),
  ),
);

/// What `autoSync` runs: the [syncEngine]. Override it with an app's own [SyncRunner] when
/// something else syncs (a Rust core), and keep `autoSync`, the triggers and `Served`.
final syncRunner = Provider<SyncRunner>((ref) => ref.watch(syncEngine));
