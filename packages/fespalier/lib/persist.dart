/// What an app needs to write its own `dataCacheStorage` (since 0.8.1): Riverpod's
/// experimental offline-persistence types, re-exported so the app needn't depend on
/// hooks_riverpod directly.
///
/// Not in `fespalier.dart`, so `Storage` can't clash with `dart:html`'s or a plugin's.
/// Riverpod marks this API experimental: a 3.x minor may change it.
library;

export 'package:hooks_riverpod/experimental/persist.dart'
    show
        Storage,
        PersistedData,
        StorageOptions,
        StorageCacheTime,
        NotifierPersistX;
