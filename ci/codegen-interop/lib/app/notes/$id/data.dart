import 'package:fespalier/fespalier.dart';
import 'package:interop_app/models/note.dart';

/// Saved for the next start as JSON, through the app's `dataCacheStorage`.
final dataCache = DataCache<Note>.json(
  toJson: (n) => n.toJson(),
  fromJson: (j) => Note.fromJson(j! as Map<String, Object?>),
);

Future<Note> data(Ref ref, {required int id}) async =>
    Note(id: id, title: 'Note $id', tags: const ['saved']);
