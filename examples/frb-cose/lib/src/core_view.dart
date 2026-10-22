import 'core.dart';
import 'device_key.dart';

/// What the `/core` page shows: the device key and how it is held, whether the server registered it, and the journal of
/// the calls the core accepted. Read from the core, never from a copy.
final class CoreView {
  /// A view of a core that is in this build.
  const CoreView({
    required this.kid,
    required this.keyKind,
    required this.registered,
    required this.journal,
  }) : available = true;

  /// The view of a build without a core (the web).
  const CoreView.unavailable()
    : available = false,
      kid = '',
      keyKind = DeviceKeyKind.none,
      registered = false,
      journal = const [];

  /// The view of [core] now, with its key held as [keyKind].
  factory CoreView.of(NotesCore core, {required DeviceKeyKind keyKind}) {
    if (!core.available) return const CoreView.unavailable();
    final status = core.status();
    return CoreView(
      kid: status.kid,
      keyKind: keyKind,
      registered: status.registered,
      journal: core.journal(),
    );
  }

  /// Whether a core is in this build.
  final bool available;

  /// The device key's kid (hex).
  final String kid;

  /// How the key is held: in a secure element, as a software key, or as a software key in memory.
  final DeviceKeyKind keyKind;

  /// Whether the server has registered the key.
  final bool registered;

  /// The journal's rows, oldest first.
  final List<JournalEntry> journal;
}
