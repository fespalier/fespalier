import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:offline/app.g.dart';
import 'package:offline/shop.dart';

class NotesPage extends ConsumerWidget {
  const NotesPage(this.notes, {super.key});

  final List<Note> notes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final add = NotesRoute.useAdd(ref);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: add.isPending
            ? null
            : () async {
                final id = await add.call('New note');
                if (id != null && context.mounted) {
                  NoteEditRoute(id: id).go(context);
                }
              },
        label: const Text('New note'),
        icon: const Icon(Icons.add),
      ),
      body: ListView(
        children: [
          for (final note in notes)
            ListTile(
              title: Text(note.title),
              subtitle: Text(note.body),
              trailing: note.waiting ? const Text('Waiting to sync') : null,
              onTap: () => NoteEditRoute(id: note.id).go(context),
            ),
        ],
      ),
    );
  }
}
