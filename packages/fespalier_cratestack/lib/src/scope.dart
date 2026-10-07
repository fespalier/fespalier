import 'dart:async';

import 'package:fespalier/fespalier.dart' show Provider;

import 'future_or.dart';
import 'local_store.dart';
import 'read_cache.dart';

/// The account whose data is read and written: null when signed out.
///
/// Override with `(ref) => ref.watch(authUserId)` (fespalier_auth). One account's data and
/// "as of" never reach another: everything this package stores is keyed by it.
final crateStackScope = Provider<String?>((ref) => null);

/// The key prefix of everything [scope] owns in a `LocalStore`: `cs/<scope>/`. The scope is
/// percent-encoded, so no scope is the prefix of another.
String scopePrefix(String scope) => 'cs/${Uri.encodeComponent(scope)}/';

/// A count per account that goes up each time the account's data is wiped.
///
/// An operation that started for an account captures its count, and checks it again after every
/// `await`, before every write: if it moved, the data the operation was working on is gone, and what
/// it holds must be dropped, not written back (a wiped intent, or a read of a signed-out account,
/// would come back otherwise).
final class WipeGenerations {
  /// No account wiped yet.
  WipeGenerations();

  final Map<String, int> _counts = {};

  /// The count of [scope].
  int of(String scope) => _counts[scope] ?? 0;

  /// [scope]'s data was (or is being) wiped.
  void wiped(String scope) => _counts[scope] = of(scope) + 1;
}

/// The wipe counts the intent queue, owned rows, the sync engine and `serve` share.
final crateStackWipes = Provider<WipeGenerations>((ref) => WipeGenerations());

/// What a sign-out wipes: the intents, owned rows, cursors and cached reads of one account.
final class CrateStackAccount {
  /// The wiper over [store] and [cache], for the scope [scope] answers.
  CrateStackAccount({
    required LocalStore store,
    required ReadCache cache,
    required String? Function() scope,
    WipeGenerations? wipes,
  }) : _store = store,
       _cache = cache,
       _scope = scope,
       _wipes = wipes ?? WipeGenerations();

  final LocalStore _store;
  final ReadCache _cache;
  final String? Function() _scope;
  final WipeGenerations _wipes;

  /// Deletes every intent, owned row, sync cursor and cached read of [scope] (default: the current
  /// scope; a sign-out passes the account it is leaving, because the scope may already be null).
  ///
  /// Sending A's intent under B's session is worse than losing it, so a sign-out calls this. Does
  /// nothing when there is no scope. The device's node id stays: it names the device, not a person.
  FutureOr<void> clear({String? scope}) {
    final target = scope ?? _scope();
    if (target == null) return null;
    // Before, so a write that is in flight is dropped; after, so one that started meanwhile is too.
    _wipes.wiped(target);
    return andThen<void, void>(
      _store.clear(scopePrefix(target)),
      (_) => andThen<void, void>(_cache.clear(target), (_) {
        _wipes.wiped(target);
      }),
    );
  }
}

/// The wipe for a sign-out: `ref.read(crateStackAccount).clear()` before the session ends.
final crateStackAccount = Provider<CrateStackAccount>(
  (ref) => CrateStackAccount(
    store: ref.watch(localStore),
    cache: ref.watch(readCache),
    scope: () => ref.read(crateStackScope),
    wipes: ref.watch(crateStackWipes),
  ),
);
