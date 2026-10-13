/// What tests use from fespalier_cratestack (since 0.10.0): a transport that plays the server's
/// idempotency layer, a synchronous store, a ticker a test fires, an in-memory row server, and the
/// override list that wires them. Nothing here starts a timer: every answer is a `Future.value`.
///
/// ```dart
/// final transport = FakeCrateStackTransport()..on('cancelOrder', (input) => {'id': 42});
/// final container = ProviderContainer(overrides: crateStackTestOverrides(transport: transport));
/// ```
library;

import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart' show RefetchSignal, appResumeSignal;
import 'package:fespalier/startup.dart' show Override;

import 'fespalier_cratestack.dart';

export 'fespalier_cratestack.dart' show InMemoryLocalStore;

/// One thing [FakeCrateStackTransport.calls] recorded.
typedef RecordedCall = ({CrateStackCall call, String? idempotencyKey});

final class _Scripted {
  _Scripted(this.error, this.remaining);
  final Object error;
  int remaining;
}

/// A [CrateStackTransport] that plays the server for a test (since 0.10.0).
///
/// It keeps an idempotency store keyed by key, like CrateStack's: a replay of a call that ran
/// returns the stored answer and does not run it twice, and a reused key with another body answers
/// `422` `idempotency_key_conflict`. Answers are `Future.value`s: no timer.
final class FakeCrateStackTransport implements CrateStackTransport {
  /// A server that knows no operation yet: script them with [on].
  FakeCrateStackTransport();

  /// While true, every send throws [CrateStackOffline] and nothing runs.
  bool offline = false;

  /// Every send, in order, including those that failed and those that replayed.
  final List<RecordedCall> calls = [];

  final Map<String, Object? Function(Object? input)> _handlers = {};
  final Map<String, List<_Scripted>> _failures = {};
  final Map<String, int> _lose = {};
  final Map<String, int> _runs = {};
  final Map<String, ({String body, Object? output})> _stored = {};

  /// The name [on] and the others use for [call]: an RPC call's `opId`, a REST call's `METHOD path`.
  static String nameOf(CrateStackCall call) => switch (call) {
    RpcCall(:final opId) => opId,
    RestCall(:final method, :final path) => '$method $path',
  };

  /// Scripts the answer of [name] (an `opId`, or `METHOD path`): [handler] gets the wire input.
  void on(String name, Object? Function(Object? input) handler) =>
      _handlers[name] = handler;

  /// Makes [name] answer with a refusal (the server decided: it did not run). `5xx` statuses are
  /// [CrateStackUnavailable], `401` [CrateStackUnauthenticated], and `409` [CrateStackInFlight]
  /// with [retryAfter], [CrateStackConflict] without. For the next [times] sends (default: all).
  void refuse(
    String name,
    int status,
    String code,
    String message, {
    Object? details,
    bool retryAfter = false,
    int times = 1 << 30,
  }) => fail(
    name,
    CrateStackFailure.fromEnvelope(
      status: status,
      code: code,
      message: message,
      details: details,
      retryAfter: retryAfter,
    ),
    times: times,
  );

  /// Makes [name] throw [error] before it runs, for the next [times] sends (default: all).
  void fail(String name, Object error, {int times = 1 << 30}) =>
      (_failures[name] ??= []).add(_Scripted(error, times));

  /// Stops [fail] and [refuse] for [name].
  void heal(String name) => _failures.remove(name);

  /// The server runs the next [times] calls of [name] and stores the answer, but the client gets
  /// [CrateStackOffline]: a lost answer. The replay under the same key must not run it again.
  void loseAnswer(String name, {int times = 1}) => _lose[name] = times;

  /// How many times the server really ran [name] (a replay does not count).
  int runs(String name) => _runs[name] ?? 0;

  @override
  Future<Object?> send(CrateStackCall call, {String? idempotencyKey}) async {
    calls.add((call: call, idempotencyKey: idempotencyKey));
    if (offline) {
      throw const CrateStackOffline('FakeCrateStackTransport.offline');
    }
    final name = nameOf(call);
    final body = jsonEncode(call.toJson());
    if (idempotencyKey != null) {
      final stored = _stored[idempotencyKey];
      if (stored != null) {
        if (stored.body != body) {
          throw const CrateStackRefused(
            status: 422,
            code: 'VALIDATION_ERROR',
            message:
                'idempotency_key_conflict: the key was used with another body',
          );
        }
        return stored.output;
      }
    }
    final scripted = _failures[name];
    if (scripted != null && scripted.isNotEmpty) {
      final next = scripted.first;
      if (--next.remaining <= 0) scripted.removeAt(0);
      throw next.error;
    }
    final handler = _handlers[name];
    if (handler == null) {
      throw StateError(
        'FakeCrateStackTransport: nothing scripted for "$name" (use on())',
      );
    }
    _runs[name] = runs(name) + 1;
    final input = switch (call) {
      RpcCall(:final input) => input,
      RestCall(:final body) => body,
    };
    final output = handler(jsonDecode(jsonEncode(input)));
    if (idempotencyKey != null) {
      _stored[idempotencyKey] = (body: body, output: output);
    }
    final lose = _lose[name] ?? 0;
    if (lose > 0) {
      _lose[name] = lose - 1;
      throw const CrateStackOffline('FakeCrateStackTransport.loseAnswer');
    }
    return output;
  }
}

/// A [syncTicker] a test fires: `syncTicker.overrideWith(ManualSyncTicker.new)`, then
/// `(container.read(syncTicker.notifier) as ManualSyncTicker).tick()`.
class ManualSyncTicker extends RefetchSignal {
  /// The periodic trigger, fired by hand.
  void tick() => fire();
}

/// An in-memory [RowSync] for a test: it merges with [LwwMerge], can reject rows by id, and pages.
final class FakeRowServer implements RowSync {
  /// An empty server.
  FakeRowServer({this.pageSize = 100, this.rejectCode = 'FORBIDDEN'});

  /// How many rows a pull gives at once.
  int pageSize;

  /// The wire code a rejection carries.
  String rejectCode;

  /// While true, push and pull throw [CrateStackOffline].
  bool offline = false;

  /// The ids [push] refuses.
  final Set<String> rejectIds = {};

  /// Every push, in order.
  final List<List<OwnedRow>> pushes = [];

  /// How many pulls ran.
  var pulls = 0;

  final Map<String, Map<String, OwnedRow>> _rows = {};
  final Map<String, int> _versions = {};
  var _version = 0;

  /// The server's row, or null.
  OwnedRow? row(String collection, String id) => _rows[collection]?[id];

  /// Puts [row] on the server as another device's push would have left it.
  void put(OwnedRow row) {
    final existing = _rows[row.collection]?[row.id];
    final merged =
        (existing == null ? row.copy() : LwwMerge.merge(existing, row))
          ..dirty.clear();
    (_rows[row.collection] ??= {})[row.id] = merged;
    _versions['${row.collection}/${row.id}'] = ++_version;
  }

  @override
  Future<PushResult> push(List<OwnedRow> dirty) async {
    if (offline) throw const CrateStackOffline('FakeRowServer.offline');
    pushes.add([for (final r in dirty) r.copy()]);
    final accepted = <OwnedRow>[];
    final rejected = <RowRejection>[];
    for (final row in dirty) {
      if (rejectIds.contains(row.id)) {
        rejected.add(
          RowRejection(
            collection: row.collection,
            id: row.id,
            code: rejectCode,
            server: _rows[row.collection]?[row.id]?.copy(),
          ),
        );
        continue;
      }
      put(row);
      accepted.add(_rows[row.collection]![row.id]!.copy());
    }
    return PushResult(accepted: accepted, rejected: rejected);
  }

  @override
  Future<PullPage> pull(String collection, String? cursor) async {
    if (offline) throw const CrateStackOffline('FakeRowServer.offline');
    pulls++;
    final after = cursor == null ? 0 : int.parse(cursor);
    final rows =
        [
          for (final row
              in (_rows[collection] ?? const <String, OwnedRow>{}).values)
            if (_versions['$collection/${row.id}']! > after) row,
        ]..sort(
          (a, b) => _versions['$collection/${a.id}']!.compareTo(
            _versions['$collection/${b.id}']!,
          ),
        );
    final page = rows.take(pageSize).toList();
    final next = page.isEmpty
        ? cursor
        : '${_versions['$collection/${page.last.id}']}';
    return PullPage(
      [for (final r in page) r.copy()],
      nextCursor: next,
      hasMore: rows.length > page.length,
    );
  }
}

/// The overrides a test of a page or a provider needs (since 0.10.0): a fake [transport] (a new
/// [FakeCrateStackTransport] by default), a synchronous [store], the [scope] of a signed-in
/// account (`'test-user'`; null is signed out), the sync [triggers], and, for owned rows, a
/// [rowServer] (a `FakeRowServer`) and its [collections].
///
/// A bare `ProviderContainer` has no `WidgetsBinding`, which `appResumeSignal` needs: unless
/// [lifecycle] is true, `appResumeSignal` is a plain signal a test fires with
/// `container.read(appResumeSignal.notifier).fire()`. A `testWidgets` that drives the real resume
/// passes `lifecycle: true`.
List<Override> crateStackTestOverrides({
  CrateStackTransport? transport,
  LocalStore? store,
  String? scope = 'test-user',
  SyncTriggers triggers = const SyncTriggers(),
  RowSync? rowServer,
  List<String> collections = const [],
  bool lifecycle = false,
}) => [
  crateStackTransport.overrideWithValue(transport ?? FakeCrateStackTransport()),
  localStore.overrideWithValue(store ?? InMemoryLocalStore()),
  crateStackScope.overrideWithValue(scope),
  syncTriggers.overrideWithValue(triggers),
  if (rowServer != null) rowSync.overrideWithValue(rowServer),
  if (collections.isNotEmpty) syncCollections.overrideWithValue(collections),
  if (!lifecycle) appResumeSignal.overrideWith(RefetchSignal.new),
];
