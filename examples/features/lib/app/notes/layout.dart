import 'package:features/models/note.dart';
import 'package:flutter/material.dart';

/// A layout can take `extra` too: it gets the extra of the location it is
/// showing, so the frame can use what `NoteRoute(id: 3).go(context, extra:
/// note)` passed. The type has to agree with the pages below (`Note?`), or be
/// `Object?` to take anything. An object of another type reads as null here.
class NotesLayout extends StatelessWidget {
  const NotesLayout({super.key, required this.child, this.extra});

  final Widget child;
  final Note? extra;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('Notes frame: ${extra?.title ?? 'no extra'}'),
      Expanded(child: child),
    ],
  );
}
