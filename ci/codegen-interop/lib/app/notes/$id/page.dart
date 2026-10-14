import 'package:flutter/material.dart';
import 'package:interop_app/models/note.dart';

/// `data` is what data.dart loaded; `extra` is what `NoteRoute(id: 3).go(context,
/// extra: note)` carried, which only extra_codec.dart can bring back after a
/// restart.
class NotePage extends StatelessWidget {
  const NotePage({super.key, required this.id, required this.data, this.extra});

  final int id;
  final Note data;
  final Note? extra;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('data: ${data.title}'),
        Text('extra: ${extra?.title ?? 'none'}'),
      ],
    ),
  );
}
