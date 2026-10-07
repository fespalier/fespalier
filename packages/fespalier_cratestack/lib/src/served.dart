import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart' show Ref;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import 'errors.dart';
import 'future_or.dart';
import 'read_cache.dart';
import 'revision.dart';
import 'scope.dart';

/// Where a served value came from.
enum ServedFrom {
  /// The server answered now.
  network,

  /// The store: the server's last answer on this device, or nothing yet.
  local,
}

/// A read's value and how current it is, for a page to show ("offline copy, as of 10:42").
///
/// The name avoids clashing with fespalier's `Freshness`, which says when a read runs again.
final class Served<T> {
  /// A [value] from [source]. [fetchedAt] is when the server last answered this read for this
  /// account (null when never, on this device); [stale] says it is older than the read's `maxAge`.
  const Served(
    this.value, {
    required this.source,
    required this.fetchedAt,
    required this.stale,
  });

  /// The value.
  final T value;

  /// Where [value] came from.
  final ServedFrom source;

  /// When the server last answered this read for this account, on this device.
  final DateTime? fetchedAt;

  /// Whether [fetchedAt] is older than the read's `maxAge`.
  final bool stale;

  /// Whether the server has never answered this read on this device (an empty list offline, say).
  bool get neverFetched => fetchedAt == null;
}

/// Where a read looks first.
enum ReadPolicy {
  /// The server, then the store on a connection failure (the default): anything others can change.
  networkFirst,

  /// The store, then the server when the store has nothing: data that does not change once cached.
  cacheFirst,

  /// The store only: rows this device owns and syncs.
  localOnly,

  /// The server only; offline is `CrateStackOffline`, never a guess.
  serverOnly,
}

/// How a read's value is saved in the `ReadCache` (JSON, like `DataCache.json`).
final class ServedCodec<T> {
  /// A codec; change [version] when the saved shape changes, and old answers are dropped.
  const ServedCodec({
    required this.toJson,
    required this.fromJson,
    this.version = '1',
  });

  /// The JSON-encodable form of a value.
  final Object? Function(T value) toJson;

  /// The value of [toJson]'s result.
  final T Function(Object? json) fromJson;

  /// The saved shape's version.
  final String version;
}

/// A read with a copy on the device.
extension CrateStackServeRef on Ref {
  /// Runs a read under [policy]: on a network answer it saves the value with `fetchedAt` =
  /// `clock.now()` under [key] for the current [crateStackScope]; on `CrateStackOffline` only, it
  /// serves the saved value, or [empty] for a list (an empty list offline is an answer), or throws
  /// `CrateStackNoLocalData`. A refusal is the answer: it is rethrown, never papered over with the
  /// cache, and so is any error the app's readers do not know.
  ///
  /// Watches [crateStackScope] and `crateStackRevision(tag)` so a sign-in change or a sync
  /// rebuilds it. Nothing is saved or read while nobody is signed in (a null scope).
  ///
  /// Sync stays sync: with [ReadPolicy.localOnly], or [ReadPolicy.cacheFirst] with a hit, on a store
  /// that answers synchronously it returns a `Served<T>`, not a `Future`.
  ///
  /// [fetch] is required unless [policy] is [ReadPolicy.localOnly]. [maxAge] drives
  /// `Served.stale` (null: never stale). [tag] is the revision tag; it defaults to [key]'s prefix
  /// before the first `:`.
  FutureOr<Served<T>> serve<T>({
    required String key,
    required ServedCodec<T> codec,
    Future<T> Function()? fetch,
    ReadPolicy policy = ReadPolicy.networkFirst,
    T Function()? empty,
    Duration? maxAge,
    String? tag,
  }) {
    if (fetch == null && policy != ReadPolicy.localOnly) {
      throw ArgumentError.value(
        policy,
        'policy',
        'fespalier_cratestack: serve needs a fetch unless the policy is localOnly',
      );
    }
    final scope = watch(crateStackScope);
    watch(crateStackRevision(tag ?? _tagOf(key)));
    final cache = watch(readCache);
    final errors = read(crateStackErrors);

    Served<T>? fromCache(CachedAnswer? hit) {
      if (hit == null) return null;
      try {
        return Served<T>(
          codec.fromJson(hit.json),
          source: ServedFrom.local,
          fetchedAt: hit.fetchedAt,
          stale: _stale(hit.fetchedAt, maxAge),
        );
      } on Object {
        // A saved answer that no longer decodes is as good as none.
        return null;
      }
    }

    Served<T> nothingStored() {
      if (empty != null) {
        return Served<T>(
          empty(),
          source: ServedFrom.local,
          fetchedAt: null,
          stale: false,
        );
      }
      throw CrateStackNoLocalData(key);
    }

    FutureOr<CachedAnswer?> saved() =>
        scope == null ? null : cache.read(scope, key, codec.version);

    Future<Served<T>> fromNetwork() async {
      final T value;
      try {
        value = await fetch!();
      } on Object catch (error) {
        final failure = errors.classify(error);
        if (failure is! CrateStackOffline || policy == ReadPolicy.serverOnly) {
          if (failure is CrateStackOffline) throw failure;
          rethrow;
        }
        final hit = fromCache(await saved());
        return hit ?? nothingStored();
      }
      final at = clock.now();
      // Not for an account that signed out (or a read that was rebuilt) while the call was in
      // the air: its sign-out wipe must stay done.
      if (scope != null && mounted && read(crateStackScope) == scope) {
        try {
          await cache.write(scope, key, codec.version, codec.toJson(value), at);
        } on Object catch (error) {
          // A cache that cannot save is a missing cache, not a failed read.
          if (kDebugMode) {
            debugPrint(
              'fespalier_cratestack: could not save the read $key: $error',
            );
          }
        }
      }
      return Served<T>(
        value,
        source: ServedFrom.network,
        fetchedAt: at,
        stale: false,
      );
    }

    switch (policy) {
      case ReadPolicy.localOnly:
        return andThen<CachedAnswer?, Served<T>>(
          saved(),
          (hit) => fromCache(hit) ?? nothingStored(),
        );
      case ReadPolicy.cacheFirst:
        return andThen<CachedAnswer?, Served<T>>(saved(), (hit) {
          final served = fromCache(hit);
          return served ?? fromNetwork();
        });
      case ReadPolicy.networkFirst:
      case ReadPolicy.serverOnly:
        return fromNetwork();
    }
  }
}

String _tagOf(String key) {
  final colon = key.indexOf(':');
  return colon < 0 ? key : key.substring(0, colon);
}

bool _stale(DateTime fetchedAt, Duration? maxAge) =>
    maxAge != null && clock.now().difference(fetchedAt) > maxAge;
