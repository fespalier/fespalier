import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/persist.dart'
    show PersistedData, Storage, StorageCacheTime, StorageOptions;
import 'package:flutter/widgets.dart';

import 'catalog.dart';
import 'source.dart';
import 'translations.dart';
import 'translator.dart';

/// Override it in `startup()`: `translationsConfig.overrideWithValue(Translations(...))`
/// (since 0.10.0).
final translationsConfig = Provider<Translations>(
  (ref) => Translations.none,
  name: 'translationsConfig',
);

/// A remote catalog the app holds, fetched or read back from the cache.
@immutable
final class HeldCatalog {
  /// [catalog] with its [etag], and whether it is [fetched] in this run or [cached].
  const HeldCatalog(this.catalog, this.etag, this.origin);

  /// The messages.
  final Catalog catalog;

  /// The validator to send next time.
  final String? etag;

  /// [TranslationOrigin.remote] or [TranslationOrigin.cached].
  final TranslationOrigin origin;
}

/// What fetches landed in this container, by locale tag.
final class RemoteStore extends Notifier<Map<String, HeldCatalog>> {
  @override
  Map<String, HeldCatalog> build() => const {};

  /// Holds [held] for [tag].
  void put(String tag, HeldCatalog held) => state = {...state, tag: held};
}

/// The remote catalogs of this container. Not exported.
final remoteStore = NotifierProvider<RemoteStore, Map<String, HeldCatalog>>(
  RemoteStore.new,
  name: 'fespalier_tolgee.remote',
);

/// What the in-context panel saved: locale tag to key to text. Always empty outside it.
final class TranslationEdits
    extends Notifier<Map<String, Map<String, String>>> {
  @override
  Map<String, Map<String, String>> build() => const {};

  /// Sets [key] in [tag] to [text] at once.
  void set(String tag, String key, String text) => state = {
    ...state,
    tag: {...?state[tag], key: text},
  };
}

/// The edited layer. Not exported.
final translationEdits =
    NotifierProvider<TranslationEdits, Map<String, Map<String, String>>>(
      TranslationEdits.new,
      name: 'fespalier_tolgee.edits',
    );

String _cacheKey(String tag) => 'fespalier_tolgee:$tag';

/// Asks the source, reads and writes the cache: plain Dart behind one provider per container.
final class Fetcher {
  /// For one container.
  Fetcher(this._ref);

  final Ref _ref;
  final _cached = <String, HeldCatalog?>{};
  final _lastResume = <String, int>{};
  final _lastReconnect = <String, int>{};
  final _inFlight = <String>{};
  final _failed = <String>{};
  final _asked = <String>{};

  /// How many times each locale was fetched, for tests.
  final fetches = <String, int>{};

  /// The cached catalog of [tag], read synchronously when the storage allows; null otherwise.
  HeldCatalog? cached(String tag) {
    if (_cached.containsKey(tag)) return _cached[tag];
    HeldCatalog? held;
    try {
      final storage = _ref.read(dataCacheStorage);
      if (storage is Storage<String, String>) {
        final read = storage.read(_cacheKey(tag));
        if (read is! Future) {
          held = _decode(tag, read);
        }
      }
    } on Object {
      held = null;
    }
    return _cached[tag] = held;
  }

  HeldCatalog? _decode(String tag, PersistedData<String>? data) {
    if (data == null) return null;
    final expireAt = data.expireAt;
    if (expireAt != null && !expireAt.isAfter(clock.now())) return null;
    try {
      final Object? json = jsonDecode(data.data);
      if (json is! Map<String, Object?> || json['v'] != 1) return null;
      final messages = json['messages'];
      if (messages is! Map<String, Object?>) return null;
      return HeldCatalog(
        Catalog(tag, {
          for (final MapEntry(:key, :value) in messages.entries)
            if (value is String) key: value,
        }),
        json['etag'] as String?,
        TranslationOrigin.cached,
      );
    } on Object {
      return null;
    }
  }

  bool _moved(String tag, int resume, int reconnect) =>
      resume > (_lastResume[tag] ?? 0) ||
      (_failed.contains(tag) && reconnect > (_lastReconnect[tag] ?? 0));

  /// Starts a fetch for [tag] when it is the first, or when [resume] went up, or when [reconnect]
  /// went up after a failure. Never starts a second one while one is in flight: a signal that
  /// moves meanwhile is looked at again when that fetch ends.
  void ensure(String tag, {required int resume, required int reconnect}) {
    final first = _asked.add(tag);
    if (_inFlight.contains(tag)) return;
    if (first || _moved(tag, resume, reconnect)) {
      _lastResume[tag] = resume;
      _lastReconnect[tag] = reconnect;
      unawaited(_run(tag));
    } else {
      _lastResume[tag] = resume;
      // A reconnect while nothing failed is used up; one that comes after a failure is not.
      if (!_failed.contains(tag)) _lastReconnect[tag] = reconnect;
    }
  }

  Future<void> _run(String tag) async {
    final config = _ref.read(translationsConfig);
    final remote = config.remote;
    if (remote == null) return;
    _inFlight.add(tag);
    try {
      // A second pass at most: a resume or a reconnect that came while the first was running.
      for (var pass = 0; pass < 2; pass++) {
        await _once(tag, config, remote);
        if (!_ref.mounted) return;
        final resume = config.refreshOnResume ? _ref.read(appResumeSignal) : 0;
        final reconnect = config.refreshOnReconnect
            ? _ref.read(reconnectSignal)
            : 0;
        if (!_moved(tag, resume, reconnect)) break;
        _lastResume[tag] = resume;
        _lastReconnect[tag] = reconnect;
      }
    } finally {
      _inFlight.remove(tag);
    }
  }

  Future<void> _once(
    String tag,
    Translations config,
    TranslationSource remote,
  ) async {
    var held = _ref.read(remoteStore)[tag] ?? cached(tag);
    if (held == null) {
      try {
        final storage = _ref.read(dataCacheStorage);
        if (storage is Future) {
          final ready = await storage;
          if (ready != null) {
            held = _decode(tag, await ready.read(_cacheKey(tag)));
          }
          if (!_ref.mounted) return;
          if (held != null) _ref.read(remoteStore.notifier).put(tag, held);
        }
      } on Object {
        // A storage that cannot be read: the network is still asked.
        held = null;
      }
    }
    try {
      fetches[tag] = (fetches[tag] ?? 0) + 1;
      final fresh = await remote.fetch(tag, etag: held?.etag);
      if (!_ref.mounted) return;
      _failed.remove(tag);
      if (fresh == null) {
        // Not changed since the validator we sent (a 304): the entry is as new as this check.
        if (held != null && held.etag != null) {
          await _write(tag, held, config.cacheMaxAge);
        }
        return;
      }
      final next = HeldCatalog(
        Catalog(tag, fresh.catalog.messages),
        fresh.etag,
        TranslationOrigin.remote,
      );
      _ref.read(remoteStore.notifier).put(tag, next);
      await _write(tag, next, config.cacheMaxAge);
    } on Object {
      // The app keeps what it has: the cache, then the bundled text.
      _failed.add(tag);
    }
  }

  final _translators = <String, Translator>{};

  /// [next], or the translator made earlier for [key] when it reads the very same catalogs, so
  /// a resume signal that fetched nothing rebuilds no `tr` reader.
  Translator reuse(String key, Translator next) {
    final previous = _translators[key];
    if (previous != null && previous.sameLayersAs(next)) return previous;
    return _translators[key] = next;
  }

  Future<void> _write(String tag, HeldCatalog held, Duration maxAge) async {
    try {
      final storage = await _ref.read(dataCacheStorage);
      if (storage == null) return;
      final json = jsonEncode({
        'v': 1,
        'etag': held.etag,
        'messages': held.catalog.messages,
      });
      await storage.write(
        _cacheKey(tag),
        json,
        StorageOptions(cacheTime: StorageCacheTime(maxAge)),
      );
      _cached[tag] = held;
    } on Object {
      // A cache that cannot be written is only a cache.
    }
  }
}

/// The container's fetcher. Not exported.
final fetcher = Provider<Fetcher>(
  Fetcher.new,
  name: 'fespalier_tolgee.fetcher',
);

/// The family behind [translator]. Not exported.
final translatorProvider = Provider.family<Translator, String>((ref, locale) {
  final config = ref.watch(translationsConfig);
  final base = config.baseLocale;
  if (config.supportedLocales.isNotEmpty && config.bundled[base] == null) {
    throw StateError(
      'fespalier_tolgee: the base locale "$base" is not bundled '
      '(bundled: ${config.supportedLocales.join(', ')})',
    );
  }
  final tag = config.resolve(locale) ?? base;
  final remote = config.remote;
  final resume = remote != null && config.refreshOnResume
      ? ref.watch(appResumeSignal)
      : 0;
  final reconnect = remote != null && config.refreshOnReconnect
      ? ref.watch(reconnectSignal)
      : 0;
  final language = tag.split(RegExp('[-_]')).first;
  final chain = <String>[
    for (final t in {tag, language, base})
      if (t.isNotEmpty && (t == tag || config.bundled[t] != null)) t,
  ];
  // Only the chain's own entries: a fetch for another locale rebuilds nobody here.
  final held = ref
      .watch(
        remoteStore.select((all) => _Slice([for (final t in chain) all[t]])),
      )
      .entries;
  final edits = ref.watch(translationEdits);
  final loader = ref.read(fetcher);
  if (remote != null && tag.isNotEmpty) {
    loader.ensure(tag, resume: resume, reconnect: reconnect);
  }
  final layers = <TranslatorLayer>[];
  for (var n = 0; n < chain.length; n++) {
    final t = chain[n];
    final edited = edits[t];
    if (edited != null && edited.isNotEmpty) {
      layers.add((
        origin: TranslationOrigin.edited,
        catalog: Catalog(t, edited),
      ));
    }
    final remoteHeld = held[n] ?? loader.cached(t);
    if (remoteHeld != null) {
      layers.add((origin: remoteHeld.origin, catalog: remoteHeld.catalog));
    }
    final bundled = config.bundled[t];
    if (bundled != null) {
      layers.add((origin: TranslationOrigin.bundled, catalog: bundled));
    }
  }
  return loader.reuse(
    locale,
    Translator(tag, layers, onMissing: config.onMissing),
  );
}, name: 'fespalier_tolgee.translator');

/// The translator for [locale] (resolved with `Translations.resolve`, else the base). Its value
/// is there at once: never an `AsyncValue`, never loading. It updates when a fetch for a locale
/// in its chain lands (since 0.10.0).
///
/// The remote and cached catalogs are saved in fespalier's `dataCacheStorage` (key
/// `fespalier_tolgee:<tag>`), so a synchronous storage (fespalier_storage's `PrefsDataStorage`)
/// has them on the first frame.
ProviderListenable<Translator> translator(String locale) =>
    translatorProvider(locale);

/// The device's preferred supported locale (the platform's locales, read synchronously), else the
/// base. For a root `redirect.dart` that picks the first URL. Override it with the user's own
/// setting (since 0.10.0).
final preferredLocale = Provider<String>((ref) {
  final config = ref.watch(translationsConfig);
  List<Locale> locales;
  try {
    locales = WidgetsBinding.instance.platformDispatcher.locales;
  } on Object {
    locales = PlatformDispatcher.instance.locales;
  }
  for (final locale in locales) {
    final tag = config.resolve(locale.toLanguageTag());
    if (tag != null) return tag;
  }
  return config.baseLocale;
}, name: 'preferredLocale');

/// The held catalogs of one translator's chain, equal when they are the same objects.
@immutable
final class _Slice {
  const _Slice(this.entries);

  final List<HeldCatalog?> entries;

  @override
  bool operator ==(Object other) {
    if (other is! _Slice || other.entries.length != entries.length) {
      return false;
    }
    for (var i = 0; i < entries.length; i++) {
      if (!identical(entries[i], other.entries[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(entries.map(identityHashCode));
}
