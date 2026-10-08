import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:offline/shop.dart';

/// One note, read locally. A note nothing here has is an error (error.dart's default), not an empty page.
FutureOr<Note> data(Ref ref, {required String id}) {
  ref.watch(crateStackRevision('notes'));
  final row = ref.watch(ownedRows).get('notes', id);
  return row is Future<OwnedRow?>
      ? row.then((r) => _note(id, r))
      : _note(id, row);
}

Note _note(String id, OwnedRow? row) {
  if (row == null || row.deleted) throw StateError('no note $id on this phone');
  return Note.fromRow(row);
}
