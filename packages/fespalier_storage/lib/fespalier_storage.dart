/// Storages for fespalier's `dataCache` (since 0.9.0): `PrefsDataStorage` (shared_preferences) and
/// `HiveDataStorage` (hive_ce). Open one in startup(), give it to `dataCacheStorage`, and a route's saved value is on
/// the first frame of the next start. Both keep to a size budget, evict the entries written longest ago, and drop
/// what they cannot read.
library;

export 'src/errors.dart' show DataEntryTooLarge;
export 'src/hive.dart' show HiveDataStorage;
export 'src/prefs.dart' show PrefsDataStorage;
