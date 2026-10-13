/// A durable [HiveLocalStore] for fespalier_cratestack (since 0.10.0): a hive_ce `Box<String>`
/// that never evicts, so a queued intent and an unpushed row survive a restart.
///
/// A separate library, so an app that brings its own store links no Hive.
library;

export 'src/hive_store.dart' show HiveLocalStore;
