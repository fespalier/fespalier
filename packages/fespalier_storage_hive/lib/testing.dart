/// What tests use from fespalier_storage_hive (since the release after 0.25.0).
library;

import 'dart:typed_data';

import 'package:hive_ce/hive.dart';

var _boxes = 0;

/// A Hive box in memory, empty, for `HiveDataStorage(await memoryBox())` (since 0.9.0). Opened with `bytes:`, so no
/// file, no plugin, and it completes under testWidgets' fake async. Each call opens a new box (a unique name when
/// [name] is null; an open box of that name is closed first). `addTearDown(box.close)`.
Future<Box<String>> memoryBox([String? name]) async {
  final boxName = name ?? 'fespalier_storage_memory_${_boxes++}';
  if (Hive.isBoxOpen(boxName)) await Hive.box<String>(boxName).close();
  return Hive.openBox<String>(boxName, bytes: Uint8List(0));
}
