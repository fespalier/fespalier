import 'package:fespalier/fespalier.dart';
import 'package:frb_cose_example/src/changes.dart';
import 'package:frb_cose_example/src/core.dart';
import 'package:frb_cose_example/src/core_view.dart';
import 'package:frb_cose_example/src/device_key.dart';

/// The core's state for `/core`: the device key and how it is held, the registration and the journal, read from the core.
///
/// It watches the feed: each event the core emits rebuilds the page, so the page shows a call as it happens, without
/// a timer. Synchronous, like any `data.dart` that has what it shows already.
CoreView data(Ref ref) {
  ref.watch(coreChanges.any);
  return CoreView.of(ref.watch(notesCore), keyKind: ref.watch(deviceKeyKind));
}
