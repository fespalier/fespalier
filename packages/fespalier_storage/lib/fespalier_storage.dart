/// Storages for fespalier's `dataCache` (since 0.9.0): `PrefsDataStorage` (shared_preferences) and
/// `HiveDataStorage` (hive_ce). Open one in startup(), give it to `dataCacheStorage`, and a route's saved value is on
/// the first frame of the next start. Both keep to a size budget, evict the entries written longest ago, and drop
/// what they cannot read.
///
/// Since the release after 0.25.0, `HiveDataStorage` and the core both are built on are `fespalier_storage_hive`'s,
/// re-exported here: an app that wants Hive alone depends on that package instead, and gets no shared_preferences.
library;

export 'package:fespalier_storage_hive/fespalier_storage_hive.dart'
    show DataEntryTooLarge, HiveDataStorage;

export 'src/prefs.dart' show PrefsDataStorage;
