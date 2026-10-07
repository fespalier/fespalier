import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// What the user chose when asked about unsaved changes (since 0.11.0).
enum LeaveChoice {
  /// Keep editing: the page stays.
  stay,

  /// Lose the changes: the page goes, and the form keeps no draft.
  discard,

  /// Keep the changes as a draft: the page goes, and the form is found as it was on return.
  keep,
}

/// Asks the user about the changes on the page that is going (since 0.11.0): the question
/// `leaveIfClean` puts when a form has unsaved changes. [context] is the root navigator's (a
/// sheet opens above every layout), [page] says whether a draft can be [PageLeave.canKeep]t.
///
/// May answer at once or later. A prompt that is dismissed answers [LeaveChoice.stay].
typedef LeavePrompt =
    FutureOr<LeaveChoice> Function(BuildContext context, PageLeave page);

/// The question `leaveIfClean` asks (since 0.11.0): by default [askToLeaveSheet], a bottom sheet
/// built on Flutter's `showModalBottomSheet`. Override it for the whole app:
///
/// ```dart
/// ProviderScope(
///   overrides: [leavePrompt.overrideWithValue(askToLeaveSheet(messages: frenchMessages))],
///   child: const App(),
/// )
/// ```
///
/// An app on material_ui's `MaterialApp` has no `MaterialLocalizations`, which Flutter's sheet
/// needs: override it with a prompt of that library's own (docs/forms.md, "Leaving with unsaved
/// changes"). Tests answer it with `LeavePrompts.answer`.
final leavePrompt = Provider<LeavePrompt>((ref) => askToLeaveSheet());

/// The texts of [askToLeaveSheet] (since 0.11.0), English by default. Pass your own, translated.
final class LeaveSheetMessages {
  /// The English defaults, or the messages given.
  const LeaveSheetMessages({
    this.title = 'Discard your changes?',
    this.body = 'What you changed on this page has not been saved.',
    this.stay = 'Keep editing',
    this.discard = 'Discard',
    this.keep = 'Keep as draft',
  });

  /// The sheet's heading.
  final String title;

  /// The line under it.
  final String body;

  /// The button that keeps the page.
  final String stay;

  /// The button that loses the changes.
  final String discard;

  /// The button that saves a draft; shown only when the page can keep one.
  final String keep;
}

/// A bottom sheet that asks what to do with unsaved changes (since 0.11.0): "Keep editing" and
/// "Discard", and "Keep as draft" when [PageLeave.canKeep]. It is the default of [leavePrompt].
///
/// Dismissing it (a tap on the scrim, a swipe down) is "Keep editing". It needs Flutter's
/// `MaterialLocalizations`, so it fits an app on `MaterialApp`.
LeavePrompt askToLeaveSheet({
  LeaveSheetMessages messages = const LeaveSheetMessages(),
}) => (context, page) async {
  final choice = await showModalBottomSheet<LeaveChoice>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(messages.title, style: Theme.of(sheet).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(messages.body),
            const SizedBox(height: 16),
            if (page.canKeep) ...[
              FilledButton(
                onPressed: () => Navigator.of(sheet).pop(LeaveChoice.keep),
                child: Text(messages.keep),
              ),
              const SizedBox(height: 8),
            ],
            OutlinedButton(
              onPressed: () => Navigator.of(sheet).pop(LeaveChoice.stay),
              child: Text(messages.stay),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(sheet).pop(LeaveChoice.discard),
              child: Text(messages.discard),
            ),
          ],
        ),
      ),
    ),
  );
  return choice ?? LeaveChoice.stay;
};

/// What a `leave.dart` returns for a page whose only question is unsaved changes (since 0.11.0):
///
/// ```dart
/// LeaveResult leave(BuildContext context, Ref ref, {required PageLeave page}) =>
///     leaveIfClean(context, ref, page);
/// ```
///
/// A clean page goes at once, with a synchronous `true` (no `Future`, no microtask). Otherwise
/// it asks [ask], or the app's [leavePrompt], and acts on the answer: [LeaveChoice.stay] is
/// `false`; [LeaveChoice.discard] calls `page.discard()` and is `true`; [LeaveChoice.keep]
/// waits for `page.keep()` and is `true`.
LeaveResult leaveIfClean(
  BuildContext context,
  Ref ref,
  PageLeave page, {
  LeavePrompt? ask,
}) {
  if (!page.isDirty) return true;
  final LeavePrompt prompt = ask ?? ref.read(leavePrompt);
  final answer = prompt(context, page);
  if (answer is Future<LeaveChoice>) {
    return answer.then<bool>((choice) => _act(page, choice));
  }
  return _act(page, answer);
}

FutureOr<bool> _act(PageLeave page, LeaveChoice choice) {
  switch (choice) {
    case LeaveChoice.stay:
      return false;
    case LeaveChoice.discard:
      page.discard();
      return true;
    case LeaveChoice.keep:
      return page.keep().then<bool>((_) => true);
  }
}
