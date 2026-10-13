import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// What the new-doc page holds that would be lost: the text typed and not saved. The page
/// registers it in its `LeaveScope`, so `docs/new/leave.dart` can ask `page.isDirty`.
class NewDocSource extends ChangeNotifier implements LeaveSource {
  String _text = '';

  /// The text as it is now.
  String get text => _text;

  /// The user typed, or [discard]ed.
  void write(String text) {
    if (text == _text) return;
    _text = text;
    notifyListeners();
  }

  @override
  bool get isDirty => _text.isNotEmpty;

  @override
  bool get canKeep => false;

  @override
  void keep() {}

  @override
  void discard() => write('');
}

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
