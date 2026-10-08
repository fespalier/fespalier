import 'package:cose_example/app.g.dart';
import 'package:cose_example/src/notes.dart';
import 'package:cose_example/src/wiring.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter/material.dart';

/// The device's notes, and a field to add one.
///
/// Every call behind it is a COSE_Sign1 message signed by the device key. The page says where
/// what it shows came from (`notes.source`): the server's sealed, verified answer, or the copy
/// the device kept of the last one.
class HomePage extends HookConsumerWidget {
  const HomePage({super.key, required this.notes});

  /// From data.dart: the list and how current it is.
  final Served<List<Note>> notes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = useTextEditingController();
    final add = HomeRoute.useAction(ref);
    final sent = useState<String?>(null);
    final waiting = ref.watch(pendingIntents(null)).value?.length ?? 0;
    final identity = ref.watch(deviceIdentity);
    final fieldError = add.fieldErrors?.fields['input'];

    Future<void> addNote() async {
      final outcome = await add.call(text.text);
      switch (outcome) {
        case Accepted<Note>(:final value):
          text.clear();
          sent.value = 'Saved as note #${value.id}';
        case Queued<Note>(:final intent):
          text.clear();
          sent.value =
              'No answer yet. Kept under key ${intent.idempotencyKey}; '
              'it is sent again, signed anew, when you tap "Send waiting".';
        case null:
          // Refused on the device (validate) or by the server: `add` shows it.
          sent.value = null;
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Notes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Device key ${kidHex(identity)}'),
          Text(
            notes.source == ServedFrom.network
                ? 'Answered by the server: sealed, and verified here.'
                : 'The server did not answer: the copy of '
                      '${notes.fetchedAt ?? 'a read that never happened'}.',
          ),
          const SizedBox(height: 16),
          if (notes.value.isEmpty) const Text('No notes yet.'),
          for (final note in notes.value)
            ListTile(
              leading: Text('#${note.id}'),
              title: Text(note.text),
              contentPadding: EdgeInsets.zero,
            ),
          const SizedBox(height: 16),
          TextField(
            controller: text,
            decoration: InputDecoration(
              labelText: 'New note',
              errorText: fieldError,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: add.isPending ? null : addNote,
            child: Text(add.isPending ? 'Sending...' : 'Add'),
          ),
          if (add.hasError && add.fieldErrors == null)
            Text("The server refused it: ${add.state.error}"),
          if (sent.value case final message?) Text(message),
          if (waiting > 0)
            OutlinedButton(
              onPressed: () async {
                final report = await ref.read(intentQueue).drain();
                sent.value = report.accepted > 0
                    ? 'Sent ${report.accepted} waiting.'
                    : 'Still no answer; they stay under their keys.';
              },
              child: Text('Send waiting ($waiting)'),
            ),
        ],
      ),
    );
  }
}
