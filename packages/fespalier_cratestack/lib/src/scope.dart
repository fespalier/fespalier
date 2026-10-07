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

/// What a sign-out wipes: the intents, owned rows, cursors and cached reads of one account.
final class CrateStackAccount {
  /// The wiper over [store] and [cache], for the scope [scope] answers.
  CrateStackAccount({
    required LocalStore store,
    required ReadCache cache,
    required String? Function() scope,
  }) : _store = store,
       _cache = cache,
       _scope = scope;

  final LocalStore _store;
  final ReadCache _cache;
  final String? Function() _scope;

  /// Deletes every intent, owned row, sync cursor and cached read of [scope] (default: the current
  /// scope; a sign-out passes the account it is leaving, because the scope may already be null).
  ///
  /// Sending A's intent under B's session is worse than losing it, so a sign-out calls this. Does
  /// nothing when there is no scope. The device's node id stays: it names the device, not a person.
  FutureOr<void> clear({String? scope}) {
    final target = scope ?? _scope();
    if (target == null) return null;
    return andThen<void, void>(
      _store.clear(scopePrefix(target)),
      (_) => _cache.clear(target),
    );
  }
}

/// The wipe for a sign-out: `ref.read(crateStackAccount).clear()` before the session ends.
final crateStackAccount = Provider<CrateStackAccount>(
  (ref) => CrateStackAccount(
    store: ref.watch(localStore),
    cache: ref.watch(readCache),
    scope: () => ref.read(crateStackScope),
  ),
);
