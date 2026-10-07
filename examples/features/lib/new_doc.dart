import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// What the new-doc page has typed and not saved. `docs/new/leave.dart` asks while it is not empty.
class NewDocDraft extends Notifier<String> {
  @override
  String build() => '';

  /// The text as it is now.
  void write(String text) => state = text;
}

/// The draft of the new doc, in the app's container: `leave()` reads it through its `Ref`.
final newDocDraft = NotifierProvider<NewDocDraft, String>(NewDocDraft.new);

/// A question in a bottom sheet (not a dialog), the way an app asks before something is lost:
/// true when the user chose to discard it.
Future<bool> askToDiscard(BuildContext context) async {
  final discard = await showModalBottomSheet<bool>(
    context: context,
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Discard this doc?'),
        TextButton(
          onPressed: () => Navigator.of(sheet).pop(false),
          child: const Text('Keep editing'),
        ),
        TextButton(
          onPressed: () => Navigator.of(sheet).pop(true),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  return discard ?? false;
}
