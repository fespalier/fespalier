import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:frb_cose_example/src/notes.dart';

/// A note is not empty: checked on the device, before anything is saved or sent.
FieldErrors? validate(String input) =>
    input.trim().isEmpty ? FieldErrors({'input': 'Write something'}) : null;

/// Nothing to invalidate by name: an accepted intent bumps the `notes` revision tag (`touches`), which `data.dart`'s
/// `ref.serve` watches, whether the answer came now or from a later drain. A queued one is bumped by [action] itself.
const invalidates = <Object>[];

/// Adds a note: a signed write, as an **intent**.
///
/// The call is saved first, and then sent through the core (`CoreTransport`). A refusal is thrown (the person is on the
/// screen that asked). No answer (offline, a 401, a sealed answer that did not open) leaves the intent pending under
/// its `Idempotency-Key`, and the page says so (`Queued`): the next drain sends it again, sealed anew by the core, under
/// the same key.
///
/// **A queued write reads the list again.** Nothing was accepted, so no `touches` tag moves; the action bumps the
/// `notes` tag itself, the same bump an accepted intent makes, so `data.dart` reads through the core once more. If the
/// server is still silent, `ref.serve` answers with the copy the device kept, marked `ServedFrom.local`, and the list's
/// line says so. Without this the line would go on saying "Answered by the server" above a write that was not.
Future<IntentOutcome<Note>> action(Ref ref, {required String input}) async {
  final outcome = await ref
      .read(intentQueue)
      .submit<Note>(
        RpcCall(Ops.addNote, {'text': input.trim()}),
        touches: {'notes'},
        decode: Note.fromWire,
      );
  if (outcome is Queued<Note>) ref.read(crateStackBump)({'notes'});
  return outcome;
}
