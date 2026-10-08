import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:offline/sync_notice.dart';

/// What the person changed. A field left null was not touched, so it keeps the stamp it had: a field,
/// not the row, is what two phones merge.
typedef NoteChanges = ({String? title, String? body});

/// Edits the note on this phone at once, whatever the network. Each changed field is stamped with the
/// hybrid logical clock and marked dirty; the next sync pushes it, and the server and every other phone
/// end up with the same row (the greater stamp wins a field both edited).
Future<void> edit(
  Ref ref, {
  required String id,
  required NoteChanges input,
}) async {
  await ref.read(ownedRows).edit('notes', id, {
    if (input.title != null) 'title': input.title,
    if (input.body != null) 'body': input.body,
  });
  syncSoon(ref); // save locally, then sync best-effort
}
