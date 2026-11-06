/// A storage for fespalier's `dataCache` on hive_ce alone (since the release after 0.25.0): `HiveDataStorage`, with
/// no shared_preferences in the app. `fespalier_storage` re-exports it next to `PrefsDataStorage`.
library;

export 'src/errors.dart' show DataEntryTooLarge;
export 'src/hive.dart' show HiveDataStorage;
