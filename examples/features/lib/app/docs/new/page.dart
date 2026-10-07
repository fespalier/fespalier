import 'package:features/new_doc.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// A static sibling of the catch-all: `/docs/new` is tried before `/docs/*rest`. What is typed
/// here (a button stands for typing, so the page needs no localizations) is kept in
/// [newDocDraft], and `leave.dart` asks before the page goes while it is not empty.
class NewDocPage extends ConsumerWidget {
  const NewDocPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: Column(
          children: [
            const Text('New doc'),
            TextButton(
              onPressed: () => ref.read(newDocDraft.notifier).write('typed'),
              child: const Text('Type'),
            ),
            TextButton(
              onPressed: () => ref.read(newDocDraft.notifier).write(''),
              child: const Text('Save'),
            ),
          ],
        ),
      );
}
