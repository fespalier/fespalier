import 'package:fespalier/fespalier.dart';

/// Writes a draft about a topic a word at a time, the way a language model streams its answer:
/// each item is the whole text so far. `docs/new/action.dart` streams it (since 0.25.0).
class DraftWriter {
  const DraftWriter();

  /// The draft about [topic], growing word by word.
  Stream<String> write(String topic) async* {
    var text = '';
    for (final word in ['A', 'short', 'doc', 'about', topic.trim()]) {
      // A model takes its time; the tests give a writer they feed by hand instead.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      text = text.isEmpty ? word : '$text $word';
      yield text;
    }
  }
}

/// The app's writer; a test overrides it with one it feeds.
final draftWriterProvider = Provider<DraftWriter>((ref) => const DraftWriter());
