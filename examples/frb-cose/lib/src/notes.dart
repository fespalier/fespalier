import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// The core's ops, by the names its `OPS` lists (`rust/src/core/mod.rs`): a signed read and a signed write.
abstract final class Ops {
  /// Signed read: the device's notes.
  static const listNotes = 'listNotes';

  /// Signed write: adds a note.
  static const addNote = 'addNote';
}

/// The ops the core accepts. The transport checks an op against it before the core is asked.
const coreOps = {Ops.addNote, Ops.listNotes};

/// One note, as the server's `Note` type: `{id, text}`.
final class Note {
  /// A note.
  const Note({required this.id, required this.text});

  /// A note from the core's answer or from the saved copy of a read.
  factory Note.fromWire(Object? json) {
    final map = json! as Map<String, Object?>;
    return Note(id: map['id']! as int, text: map['text']! as String);
  }

  /// The server's number for it, per device.
  final int id;

  /// What it says.
  final String text;

  /// The note as JSON, for the saved copy of a read.
  Map<String, Object?> toJson() => {'id': id, 'text': text};

  @override
  bool operator ==(Object other) =>
      other is Note && other.id == id && other.text == text;

  @override
  int get hashCode => Object.hash(id, text);
}

/// The server's `NoteList`: `{notes: [...]}`.
List<Note> notesFromWire(Object? json) => [
  for (final note in (json! as Map<String, Object?>)['notes']! as List<Object?>)
    Note.fromWire(note),
];

/// How `ref.serve` saves the list as the read copy.
///
/// **The copy and the queued writes live in memory** (the package's default `InMemoryLocalStore`; `wiring.dart` does
/// not override `localStore`): they last while the app runs, so an offline read and a write waiting for the server both
/// work, and an app restart drops them. A durable `HiveLocalStore` (`fespalier_cratestack/hive.dart`), given to
/// `localStore.overrideWithValue(...)`, is how an app keeps them across runs.
final ServedCodec<List<Note>> notesCodec = ServedCodec<List<Note>>(
  toJson: (notes) => [for (final note in notes) note.toJson()],
  fromJson: (json) => [
    for (final note in json! as List<Object?>) Note.fromWire(note),
  ],
);
