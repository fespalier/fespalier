import 'dart:math';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:offline/sync_notice.dart';

/// A new note is a row this device owns: saved here at once, offline or not, then pushed by a sync.
/// The id is random, so two phones never make the same one. Returns it, so the page can open the note.
Future<String> add(Ref ref, {required String input}) async {
  final id = Random.secure().nextInt(1 << 32).toRadixString(16);
  await ref.read(ownedRows).edit('notes', id, {'title': input, 'body': ''});
  syncSoon(ref); // save locally, then sync best-effort
  return id;
}
