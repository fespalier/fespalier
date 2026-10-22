import 'dart:typed_data';

import 'package:fespalier_keypair/fespalier_keypair.dart';

import 'core.dart';
import 'rust/api/core.dart' as rust;
import 'rust/frb_generated.dart';

// The one file that calls the generated bindings: the opaque core, the identity and the library's loader.
// (lib/src/core.dart imports the data types only.)

/// Loads the core's native library: the one `RustLib.init` the app calls, from `startup()` (through
/// `initRustCore`, so it is reported). The build's hook put the library where the app finds it.
Future<void> loadRustCore() => RustLib.init();

/// Opens the core: the server and the two keys it is given, with `signer` as the device key. Nothing is sent: the
/// registration waits for the first call.
Future<NotesCore> openNotesCore({
  required rust.CoreConfig config,
  required KeypairSigner signer,
}) async {
  final core = await rust.NotesCore.open(
    config: config,
    sign: (input) => _signature(signer, input),
  );
  return FrbNotesCore(core);
}

/// The kid and thumbprint of a device key, from its public point (x and y, 32 bytes each), as the core computes them.
rust.DeviceIdentity identityOf({required Uint8List x, required Uint8List y}) =>
    rust.deviceIdentity(deviceX: x, deviceY: y);

/// The device key's signature of the bytes the core sends it, or null. A key that refuses, a locked keystore or a
/// throw all become null: the core then refuses the call and sends nothing. The callback never throws, because a
/// throw in Dart would panic the generated Rust code.
Future<Uint8List?> _signature(KeypairSigner signer, Uint8List input) async {
  try {
    return await signer.sign(input);
  } on Object {
    return null;
  }
}

/// The core over the generated opaque object.
final class FrbNotesCore implements NotesCore {
  /// Wraps the opened core.
  FrbNotesCore(this._core);

  final rust.NotesCore _core;

  @override
  bool get available => true;

  @override
  Future<rust.CoreAnswer> call({
    required String op,
    required String argsJson,
    required String idempotencyKey,
  }) => _core.call(op: op, argsJson: argsJson, idempotencyKey: idempotencyKey);

  @override
  Stream<rust.CoreEvent> changes() => _core.changes();

  @override
  List<rust.JournalEntry> journal() => _core.journal();

  @override
  rust.CoreStatus status() => _core.status();
}
