/// Offline-first CrateStack clients for fespalier (since 0.10.0): reads that say how current they
/// are, mutations queued with idempotency keys, rows a device owns merged field by field, and the
/// triggers that sync them.
///
/// Pure Dart on top of fespalier (no Dio, no Hive, no CrateStack package): the generated client
/// reaches it through a [CrateStackTransport] and a `CrateStackErrorReader` that the app writes in
/// about ten lines. `package:fespalier_cratestack/dio.dart` adds cancellation and the Dio error
/// reader, `hive.dart` a durable store, and `testing.dart` the fakes.
///
/// ```dart
/// // lib/app/orders/data.dart
/// FutureOr<Served<List<Order>>> data(Ref ref) => ref.serve(
///   key: 'orders',
///   codec: _codec,
///   empty: () => const [],
///   fetch: () => ref.read(shopClient).models.order.list(),
/// );
/// ```
library;

export 'src/auto_sync.dart'
    show AutoSync, SyncStatus, SyncTriggers, autoSync, syncTicker, syncTriggers;
export 'src/errors.dart';
export 'src/field_errors.dart'
    show CrateStackFieldErrors, CrateStackFieldErrorsOf;
export 'src/hlc.dart' show Hlc;
export 'src/intent.dart';
export 'src/intent_queue.dart'
    show IntentQueue, idempotencyKeyConflict, intentQueue, pendingIntents;
export 'src/local_store.dart' show InMemoryLocalStore, LocalStore, localStore;
export 'src/lww.dart' show LwwMerge, OwnedRow, tombstoneField;
export 'src/owned_rows.dart' show OwnedRows, ownedRows;
export 'src/read_cache.dart' show CachedAnswer, ReadCache, readCache;
export 'src/revision.dart'
    show
        BumpTags,
        RevisionCounter,
        crateStackBump,
        crateStackRevision,
        intentsTag;
export 'src/row_sync.dart'
    show PullPage, PushResult, RowRejection, RowSync, rowSync, syncCollections;
export 'src/scope.dart'
    show CrateStackAccount, crateStackAccount, crateStackScope;
export 'src/served.dart';
export 'src/sync_engine.dart'
    show
        RolledBack,
        SyncEngine,
        SyncReason,
        SyncReport,
        SyncRunner,
        syncEngine,
        syncRunner;
export 'src/transport.dart';
