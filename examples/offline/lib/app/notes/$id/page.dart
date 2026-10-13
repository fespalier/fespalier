import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:offline/app.g.dart';
import 'package:offline/demo/demo_server.dart';
import 'package:offline/shop.dart';

class NoteEditPage extends ConsumerStatefulWidget {
  const NoteEditPage(this.note, {super.key});

  final Note note;

  @override
  ConsumerState<NoteEditPage> createState() => _NoteEditPageState();
}

class _NoteEditPageState extends ConsumerState<NoteEditPage> {
  late final _title = TextEditingController(text: widget.note.title);
  late final _body = TextEditingController(text: widget.note.body);

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final edit = NoteEditRoute.useEdit(ref, id: note.id);
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // What this phone holds now: edits made here and edits that arrived from the server, merged.
          Text('On this phone: ${note.title} / ${note.body}'),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            controller: _body,
            decoration: const InputDecoration(labelText: 'Body'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: edit.isPending
                ? null
                : () => edit.call((
                    // Only what changed: an untouched field keeps its stamp.
                    title: _title.text == note.title ? null : _title.text,
                    body: _body.text == note.body ? null : _body.text,
                  )),
            child: const Text('Save'),
          ),
          // The note on this page is the one on this phone: waiting means the server has not seen it yet.
          if (note.waiting) const Text('Waiting to sync'),
          const SizedBox(height: 32),
          // The demo's other phone: it edits the same note on the server, with a later stamp. This phone
          // gets it at its next sync and merges it with its own edits, field by field.
          OutlinedButton(
            onPressed: () => ref.read(demoServer).editOnAnotherDevice(note.id, {
              'title': '${note.title} (renamed elsewhere)',
            }),
            child: const Text('Rename on the other phone'),
          ),
        ],
      ),
    );
  }
}
