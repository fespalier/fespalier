import 'package:features/drafts.dart';
import 'package:fespalier/fespalier.dart';

/// Run before [draft]: a draft needs something to be about. The stream never starts without it.
FieldErrors? draftValidate(String input) => input.trim().isEmpty
    ? const FieldErrors({'topic': 'Type what the doc is about first'})
    : null;

/// A streaming action (since 0.25.0): drafts a doc about `input`, each item the text so far.
///
/// `NewDocRoute.useDraft(ref)` gives the page the state (running with the latest text, then done,
/// failed or cancelled) and `cancel()`; the run stops when the page goes away. The page's own
/// text is not stale after it, and this folder has no data.dart: there is nothing to invalidate.
Stream<String> draft(Ref ref, {required String input}) =>
    ref.read(draftWriterProvider).write(input);
