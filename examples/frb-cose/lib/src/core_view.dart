import 'core.dart';

/// What the `/core` page shows: the device key, whether the server registered it, and the journal of the calls the
/// core accepted. Read from the core, never from a copy.
final class CoreView {
  /// A view of a core that is in this build.
  const CoreView({
    required this.kid,
    required this.registered,
    required this.journal,
  }) : available = true;

  /// The view of a build without a core (the web).
  const CoreView.unavailable()
    : available = false,
      kid = '',
      registered = false,
      journal = const [];

  /// The view of [core] now.
  factory CoreView.of(NotesCore core) {
    if (!core.available) return const CoreView.unavailable();
    final status = core.status();
    return CoreView(
      kid: status.kid,
      registered: status.registered,
      journal: core.journal(),
    );
  }

  /// Whether a core is in this build.
  final bool available;

  /// The device key's kid (hex).
  final String kid;

  /// Whether the server has registered the key.
  final bool registered;

  /// The journal's rows, oldest first.
  final List<JournalEntry> journal;
}
