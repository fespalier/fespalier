/// What tests use from fespalier_storage (since 0.9.0).
library;

import 'dart:typed_data';

import 'package:hive_ce/hive.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Makes shared_preferences an in-memory store for this test, holding [values] (since 0.9.0). Call it in `setUp`
/// (or before `PrefsDataStorage.open()`), including in a test that boots `AppMain.root()` or `AppMain.run()`, whose
/// startup() opens one. Two `open()`s in one test share the store: that is a restart.
void fakePrefsStore([Map<String, Object> values = const {}]) {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.withData(values);
}

var _boxes = 0;

/// A Hive box in memory, empty, for `HiveDataStorage(await memoryBox())` (since 0.9.0). Opened with `bytes:`, so no
/// file, no plugin, and it completes under testWidgets' fake async. Each call opens a new box (a unique name when
/// [name] is null; an open box of that name is closed first). `addTearDown(box.close)`.
Future<Box<String>> memoryBox([String? name]) async {
  final boxName = name ?? 'fespalier_storage_memory_${_boxes++}';
  if (Hive.isBoxOpen(boxName)) await Hive.box<String>(boxName).close();
  return Hive.openBox<String>(boxName, bytes: Uint8List(0));
}
