import 'package:cose_example/src/notes.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// A note is not empty: checked on the device, before anything is saved or sent.
FieldErrors? validate(String input) =>
    input.trim().isEmpty ? FieldErrors({'input': 'Write something'}) : null;

/// Nothing to invalidate by hand: an accepted intent bumps the `notes` revision tag (`touches`),
/// which `data.dart`'s `ref.serve` watches, whether the answer came now or from a later drain.
const invalidates = <Object>[];

/// Adds a note: a signed write, as an **intent**.
///
/// The call is saved first, encoded once, and then sent through the `CoseTransport`. A refusal
/// is thrown (the person is on the screen that asked). No answer (offline, a 401, a sealed
/// answer that did not open) leaves the intent pending under its `Idempotency-Key`, and the page
/// says so (`Queued`): the next drain sends it again, sealed anew (a new `iat` and `cti`), under
/// the same key.
///
/// Why an intent and not a direct call: this is the seam that shows what signing at send time
/// is for. A direct `transport.send` would be sealed once, and a retry would have to be written
/// by hand.
Future<IntentOutcome<Note>> action(Ref ref, {required String input}) => ref
    .read(intentQueue)
    .submit<Note>(
      RpcCall(Ops.addNote, {'text': input.trim()}),
      touches: {'notes'},
      decode: Note.fromWire,
    );
