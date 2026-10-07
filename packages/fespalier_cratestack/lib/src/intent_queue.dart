import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:fespalier/fespalier.dart' show FutureProvider, Provider;

import 'errors.dart';
import 'ids.dart';
import 'intent.dart';
import 'local_store.dart';
import 'revision.dart';
import 'scope.dart';
import 'transport.dart';

/// The reason of an intent the server refused because its stored body changed under its key: a bug
/// in the caller, kept as `failed`.
const idempotencyKeyConflict = 'idempotency_key_conflict';

/// Mutations the server decides, queued on the device.
///
/// An intent is saved before it is sent, and sent from the saved text every time, so every attempt
/// is byte-identical. It is never retried here: no timer, no backoff. The next [drain] (the sync's
/// triggers) sends it again, under the same key unless the server answered with a stored failure.
final class IntentQueue {
  /// A queue over [store] for the account [scope] answers, sending through [transport] and reading
  /// errors with [errors]; [bump] is told the revision tags an accepted intent touches.
  IntentQueue({
    required LocalStore store,
    required String? Function() scope,
    required CrateStackTransport Function() transport,
    required CrateStackErrors Function() errors,
    required BumpTags bump,
  }) : _store = store,
       _scope = scope,
       _transport = transport,
       _errors = errors,
       _bump = bump;

  final LocalStore _store;
  final String? Function() _scope;
  final CrateStackTransport Function() _transport;
  final CrateStackErrors Function() _errors;
  final BumpTags _bump;

  final Set<String> _inFlight = {};
  String? _seqScope;
  int _seq = 0;

  String _prefix() {
    final scope = _scope();
    if (scope == null) {
      throw StateError(
        'fespalier_cratestack: crateStackScope is null (nobody is signed in), '
        'so an intent cannot be saved. Override crateStackScope, and keep calls '
        'that must work signed out (a sign-in) out of the queue.',
      );
    }
    return '${scopePrefix(scope)}intent/';
  }

  Future<int> _nextSeq(String scope) async {
    if (_seqScope != scope) {
      final saved = await _store.read('${scopePrefix(scope)}seq');
      _seq = saved == null ? 0 : int.parse(saved);
      _seqScope = scope;
    }
    final next = ++_seq;
    await _store.write('${scopePrefix(scope)}seq', '$next');
    return next;
  }

  Future<void> _save(Intent intent) async {
    await _store.write('${_prefix()}${intent.id}', jsonEncode(intent.toJson()));
    _bump({intentsTag});
  }

  Future<void> _delete(Intent intent) async {
    await _store.delete('${_prefix()}${intent.id}');
    _bump({intentsTag});
  }

  /// Saves [call] as an intent, then sends it once.
  ///
  /// Accepted: deleted, the revisions in [touches] bumped, [Accepted]. No answer (offline, in
  /// flight, `401`, a stored `5xx`): [Queued]. A refusal on the spot is thrown as the
  /// `CrateStackFailure` (or `FieldErrors` through `withCrateStackFieldErrors`) and nothing is
  /// kept: the person is on the screen that asked. An error the readers do not know is rethrown
  /// as it was, and nothing is kept either.
  ///
  /// [subject] orders it behind an undecided earlier intent for the same subject. [decode] turns
  /// the server's output into the value of [Accepted].
  Future<IntentOutcome<T>> submit<T>(
    CrateStackCall call, {
    String? subject,
    Set<String> touches = const {},
    required T Function(Object? output) decode,
  }) async {
    _prefix(); // a StateError, before anything is saved, when nobody is signed in
    final scope = _scope()!;
    // Encode once, then work from what was decoded: the first attempt is the same bytes as the rest.
    final draft = Intent(
      id: randomHex(16),
      seq: await _nextSeq(scope),
      call: call,
      createdAt: clock.now(),
      subject: subject,
      touches: touches,
      status: IntentStatus.sent,
    );
    final intent = Intent.fromJson(jsonDecode(jsonEncode(draft.toJson())));
    await _save(intent);
    _inFlight.add(intent.id);
    final Object? output;
    try {
      output = await _transport().send(
        intent.call,
        idempotencyKey: intent.idempotencyKey,
      );
    } on Object catch (error, stackTrace) {
      _inFlight.remove(intent.id);
      final failure = _errors().classify(error);
      if (failure == null) {
        await _delete(intent);
        rethrow;
      }
      switch (failure) {
        case CrateStackOffline() ||
            CrateStackInFlight() ||
            CrateStackUnauthenticated() ||
            CrateStackCancelled():
          final kept = intent.copyWith(status: IntentStatus.pending);
          await _save(kept);
          return Queued<T>(kept);
        case CrateStackUnavailable():
          final kept = intent.copyWith(
            status: IntentStatus.pending,
            attempt: intent.attempt + 1,
            failures: intent.failures + 1,
          );
          await _save(kept);
          return Queued<T>(kept);
        case CrateStackRefused() ||
            CrateStackConflict() ||
            CrateStackNoLocalData():
          await _delete(intent);
          Error.throwWithStackTrace(failure, stackTrace);
      }
    }
    _inFlight.remove(intent.id);
    await _delete(intent);
    if (touches.isNotEmpty) _bump(touches);
    return Accepted<T>(decode(output));
  }

  /// Sends every pending intent, oldest first, one at a time, skipping a subject with an undecided
  /// earlier one; stops at the first [CrateStackOffline]. The answers:
  ///
  /// - success: deleted, its `touches` bumped;
  /// - no answer, `409` with `Retry-After`, `401`: `pending`, the same key;
  /// - `5xx` or an unreadable envelope: `pending`, the next key (`attempt + 1`);
  /// - `422 idempotency_key_conflict` (a bug: the stored body changed): `failed`;
  /// - `409` without `Retry-After`: `conflict`;
  /// - any other `4xx`: `failed`, with the wire code only.
  ///
  /// It never throws for a call's failure; an error the readers do not know keeps the intent
  /// pending under its key, as a lost answer would.
  Future<DrainReport> drain() async {
    if (_scope() == null) return const DrainReport();
    final all = await list();
    final blocked = <String>{
      for (final intent in all)
        if (_inFlight.contains(intent.id) && intent.subject != null)
          intent.subject!,
    };
    final touched = <String>{};
    var accepted = 0;
    var failed = 0;
    var conflicts = 0;
    var retained = 0;
    var offline = false;
    var reached = false;
    for (final saved in all) {
      if (!saved.undecided || _inFlight.contains(saved.id)) continue;
      final subject = saved.subject;
      if (subject != null && blocked.contains(subject)) continue;
      _inFlight.add(saved.id);
      try {
        final sending = saved.status == IntentStatus.sent
            ? saved
            : saved.copyWith(status: IntentStatus.sent);
        if (sending != saved) await _save(sending);
        try {
          await _transport().send(
            sending.call,
            idempotencyKey: sending.idempotencyKey,
          );
          reached = true;
          await _delete(sending);
          touched.addAll(sending.touches);
          accepted++;
        } on Object catch (error) {
          final failure = _errors().classify(error);
          switch (failure) {
            case null:
              if (kDebugMode) {
                debugPrint(
                  'fespalier_cratestack: an intent failed with an error no reader knows, '
                  'kept under its key: ${error.runtimeType}',
                );
              }
              await _save(sending.copyWith(status: IntentStatus.pending));
              retained++;
              if (subject != null) blocked.add(subject);
            case CrateStackOffline():
              await _save(sending.copyWith(status: IntentStatus.pending));
              offline = true;
            case CrateStackInFlight() ||
                CrateStackUnauthenticated() ||
                CrateStackCancelled() ||
                CrateStackNoLocalData():
              reached = reached || failure is! CrateStackCancelled;
              await _save(sending.copyWith(status: IntentStatus.pending));
              retained++;
              if (subject != null) blocked.add(subject);
            case CrateStackUnavailable():
              reached = true;
              await _save(
                sending.copyWith(
                  status: IntentStatus.pending,
                  attempt: sending.attempt + 1,
                  failures: sending.failures + 1,
                ),
              );
              retained++;
              if (subject != null) blocked.add(subject);
            case CrateStackConflict(:final code):
              reached = true;
              await _save(
                sending.copyWith(status: IntentStatus.conflict, reason: code),
              );
              conflicts++;
            case CrateStackRefused(:final code, :final message):
              reached = true;
              await _save(
                sending.copyWith(
                  status: IntentStatus.failed,
                  // Only the wire code is kept; the one bug the server names in its message
                  // (a body that changed under its key) is named by that prefix.
                  reason: message.startsWith(idempotencyKeyConflict)
                      ? idempotencyKeyConflict
                      : code,
                ),
              );
              failed++;
          }
        }
      } finally {
        _inFlight.remove(saved.id);
      }
      if (offline) break;
    }
    if (touched.isNotEmpty) _bump(touched);
    return DrainReport(
      accepted: accepted,
      failed: failed,
      conflicts: conflicts,
      retained: retained,
      offline: offline,
      reachedServer: reached,
    );
  }

  /// Every intent of this account, oldest first. Empty while nobody is signed in.
  FutureOr<List<Intent>> list() {
    if (_scope() == null) return const [];
    final prefix = _prefix();
    Future<List<Intent>> read() async {
      final keys = await _store.keys(prefix);
      final intents = <Intent>[];
      for (final key in keys) {
        final text = await _store.read(key);
        if (text == null) continue;
        try {
          intents.add(Intent.fromJson(jsonDecode(text)));
        } on Object {
          // Not an intent this version can read: left where it is, never sent.
        }
      }
      return intents..sort((a, b) => a.seq.compareTo(b.seq));
    }

    return read();
  }

  /// Deletes the intent [id]: the person gave up on a `failed` or `conflict` one.
  FutureOr<void> discard(String id) async {
    await _store.delete('${_prefix()}$id');
    _bump({intentsTag});
  }

  /// A sign-out: every intent of this account goes. Sending A's intent under B's session is worse
  /// than losing it. (`crateStackAccount.clear` does this and more.)
  FutureOr<void> clear() async {
    if (_scope() == null) return;
    await _store.clear(_prefix());
    _bump({intentsTag});
  }
}

/// The queue of the current account on the [localStore], sending through [crateStackTransport].
final intentQueue = Provider<IntentQueue>(
  (ref) => IntentQueue(
    store: ref.watch(localStore),
    scope: () => ref.read(crateStackScope),
    transport: () => ref.read(crateStackTransport),
    errors: () => ref.read(crateStackErrors),
    bump: ref.watch(crateStackBump),
  ),
);

/// The undecided intents (pending or being sent), for "3 changes waiting" and a row's
/// "cancelling...": read again on each change to the queue. Pass a subject for one thing's, null
/// for all.
final pendingIntents = FutureProvider.autoDispose.family<List<Intent>, String?>(
  (ref, subject) async {
    ref
      ..watch(crateStackRevision(intentsTag))
      ..watch(crateStackScope);
    final all = await ref.read(intentQueue).list();
    return [
      for (final intent in all)
        if (intent.undecided && (subject == null || intent.subject == subject))
          intent,
    ];
  },
);
