import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// One note, as the server's `Note` type: `{id, text}`.
final class Note {
  /// A note.
  const Note({required this.id, required this.text});

  /// A note from the server's answer or from the saved copy of a read.
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

/// How `ref.serve` saves the list on the device between runs.
final ServedCodec<List<Note>> notesCodec = ServedCodec<List<Note>>(
  toJson: (notes) => [for (final note in notes) note.toJson()],
  fromJson: (json) => [
    for (final note in json! as List<Object?>) Note.fromWire(note),
  ],
);

/// The op ids of the server's schema (`server/schema.cstack`).
abstract final class Ops {
  /// Plain: tells the server a public key.
  static const registerDevice = 'procedure.registerDevice';

  /// Signed read.
  static const listNotes = 'procedure.listNotes';

  /// Signed write.
  static const addNote = 'procedure.addNote';
}
