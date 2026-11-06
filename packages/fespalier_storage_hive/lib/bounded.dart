/// The core every fespalier storage is built on (since the release after 0.25.0): `BoundedDataStorage`, a
/// `Storage<String, String>` with a size budget over any synchronous key-value store (an `EntryStore`).
/// `fespalier_storage`'s `PrefsDataStorage` extends it; so can a storage of your own over another synchronous store.
library;

export 'src/bounded.dart'
    show BoundedDataStorage, EntryStore, checkBudget, storedKeyPrefix;
