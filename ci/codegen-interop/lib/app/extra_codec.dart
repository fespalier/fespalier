import 'package:fespalier/fespalier.dart';
import 'package:interop_app/models/note.dart';

/// `ExtraCodec({Note: ...})` looks the type up exactly, and a freezed `Note` is
/// a private `_Note`: it would save every extra as null. `ExtraCodec.of` matches
/// with `is`.
final extraCodec = ExtraCodec.of([
  ExtraType<Note>(toJson: (n) => n.toJson(), fromJson: Note.fromJson),
]);
