import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter/material.dart'
    hide Intent; // Flutter has an Intent of its own

/// Intents the server refused or answered with a conflict: kept, never sent again, until the person
/// discards them. `pendingIntents` lists only the undecided ones, so these are shown by the app.
final problems = FutureProvider.autoDispose<List<Intent>>((ref) async {
  ref.watch(
    crateStackRevision(intentsTag),
  ); // bumped whenever an intent is saved, changed or removed
  if (ref.watch(crateStackScope) == null) return const [];
  final all = await ref.read(intentQueue).list();
  return [
    for (final intent in all)
      if (!intent.undecided) intent,
  ];
});

/// What the server said about a decision it did not take. Only its wire code is stored, never its message.
class Problems extends ConsumerWidget {
  /// The list of refused and conflicting intents, empty when there are none.
  const Problems({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    children: [
      for (final intent in ref.watch(problems).value ?? const <Intent>[])
        ListTile(
          title: Text(
            intent.status == IntentStatus.conflict
                ? 'Not sent: ${intent.subject} changed meanwhile (${intent.reason})'
                : 'Not sent: the shop refused ${intent.subject} (${intent.reason})',
          ),
          subtitle: const Text('It will not be tried again.'),
          trailing: TextButton(
            onPressed: () => ref.read(intentQueue).discard(intent.id),
            child: const Text('Discard'),
          ),
        ),
    ],
  );
}
