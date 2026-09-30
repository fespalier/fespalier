import 'package:features/models/note.dart';
import 'package:flutter/material.dart';

/// `extra` is what `NoteRoute(id: 3).go(context, extra: note)` passes. It isn't
/// in the URL, so a deep link or a reload leaves it null: the type is nullable.
class NotePage extends StatelessWidget {
  const NotePage({super.key, required this.id, this.extra});

  final int id;
  final Note? extra;

  @override
  Widget build(BuildContext context) =>
      Text('Note $id: ${extra?.title ?? 'no extra'}');
}
