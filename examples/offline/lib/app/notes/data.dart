import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:offline/shop.dart';

/// The notes this device holds, read locally: a note edited a second ago is here, synced or not, and
/// the list is on the first frame (the in-memory store answers synchronously, so nothing waits).
FutureOr<List<Note>> data(Ref ref) {
  ref.watch(crateStackRevision('notes')); // an edit or a sync rebuilds the read
  if (ref.watch(crateStackScope) == null) {
    return const []; // signed out: empty, not an error
  }
  final rows = ref.watch(ownedRows).list('notes');
  return rows is Future<List<OwnedRow>> ? rows.then(_notes) : _notes(rows);
}

List<Note> _notes(List<OwnedRow> rows) =>
    [for (final row in rows) Note.fromRow(row)]
      ..sort((a, b) => a.id.compareTo(b.id));
