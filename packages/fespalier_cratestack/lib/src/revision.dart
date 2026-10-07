import 'package:fespalier/fespalier.dart'
    show Notifier, NotifierProvider, Provider;

/// A count for one tag, which the sync engine, an owned row's edit and an accepted intent bump.
class RevisionCounter extends Notifier<int> {
  /// The counter of [tag].
  RevisionCounter(this.tag);

  /// What this counter counts changes of, e.g. `orders`.
  final String tag;

  @override
  int build() => 0;

  /// Something under [tag] changed.
  void bump() => state++;
}

/// A count per tag: a `data.dart` that reads through `ref.serve` watches its tag, so a sync or an
/// accepted intent that touched it makes the read run again.
final crateStackRevision =
    NotifierProvider.family<RevisionCounter, int, String>(RevisionCounter.new);

/// Bumps the [tags]: what the intent queue and the sync engine call.
typedef BumpTags = void Function(Set<String> tags);

/// [BumpTags] over [crateStackRevision].
final crateStackBump = Provider<BumpTags>(
  (ref) => (tags) {
    for (final tag in tags) {
      ref.read(crateStackRevision(tag).notifier).bump();
    }
  },
);

/// The tag [pendingIntents] watches: bumped whenever an intent is saved, changed or removed.
const intentsTag = 'cratestack:intents';
