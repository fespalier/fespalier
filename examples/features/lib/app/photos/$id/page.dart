import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// A route shown as a dialog: `transition.dart` next to this file uses
/// `Transitions.dialog`, so the page is the dialog itself.
class PhotoPage extends StatelessWidget {
  const PhotoPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Photo $id'),
    actions: [
      TextButton(onPressed: () => context.pop(), child: const Text('Close')),
    ],
  );
}
