/// What tests use from fespalier_storage (since 0.9.0).
library;

import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

// memoryBox() is fespalier_storage_hive's (since the release after 0.25.0), re-exported so this import keeps working.
export 'package:fespalier_storage_hive/testing.dart' show memoryBox;

/// Makes shared_preferences an in-memory store for this test, holding [values] (since 0.9.0). Call it in `setUp`
/// (or before `PrefsDataStorage.open()`), including in a test that boots `AppMain.root()` or `AppMain.run()`, whose
/// startup() opens one. Two `open()`s in one test share the store: that is a restart.
void fakePrefsStore([Map<String, Object> values = const {}]) {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.withData(values);
}
