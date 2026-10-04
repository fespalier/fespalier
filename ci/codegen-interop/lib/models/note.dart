import 'package:freezed_annotation/freezed_annotation.dart';

part 'note.freezed.dart';
part 'note.g.dart';

/// A freezed class in its usual syntax: `Note(...)` is a private `_Note`, never
/// a `Note`, and json_serializable writes `fromJson` and `toJson`.
@freezed
abstract class Note with _$Note {
  const factory Note({
    required int id,
    required String title,
    @Default(<String>[]) List<String> tags,
  }) = _Note;

  factory Note.fromJson(Map<String, dynamic> json) => _$NoteFromJson(json);
}
