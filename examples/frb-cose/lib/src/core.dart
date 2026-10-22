import 'package:fespalier/fespalier.dart';

import 'rust/api/core.dart'
    show
        CoreAnswer,
        CoreError,
        CoreErrorKind,
        CoreEvent,
        CoreStatus,
        DeviceIdentity,
        JournalEntry;

// The generated bindings' data types cross this seam as they are: a plain class each. Only this file and
// frb_core.dart import lib/src/rust/ (test/bindings_boundary_test.dart checks it).
export 'rust/api/core.dart'
    show
        CoreAnswer,
        CoreConfig,
        CoreError,
        CoreErrorKind,
        CoreEvent,
        CoreEventKind,
        CoreStatus,
        DeviceIdentity,
        JournalEntry,
        JournalOutcome;

/// The Rust core as the app sees it. `FrbNotesCore` (frb_core.dart) is the real one; [UnavailableCore] is the core
/// of a web build. A test passes a fake.
abstract interface class NotesCore {
  /// Whether a core is in this build. False on the web: nothing is called and nothing is sent.
  bool get available;

  /// One sealed call. `op` is the core's name for it, `argsJson` its arguments as JSON and `idempotencyKey` the key
  /// a write sends (empty for a read). Throws a [CoreError] for a failure the core reports.
  Future<CoreAnswer> call({
    required String op,
    required String argsJson,
    required String idempotencyKey,
  });

  /// The core's events: the last few so far, then each new one.
  Stream<CoreEvent> changes();

  /// The journal's rows, oldest first (the newest 32).
  List<JournalEntry> journal();

  /// The core's state, read without a call.
  CoreStatus status();
}

/// The core of a build that has none (the web): every call fails the way an unreachable server does, the event
/// stream is empty and there is no journal.
final class UnavailableCore implements NotesCore {
  /// The core of a build without one.
  const UnavailableCore();

  @override
  bool get available => false;

  @override
  Future<CoreAnswer> call({
    required String op,
    required String argsJson,
    required String idempotencyKey,
  }) => Future<CoreAnswer>.error(
    const CoreError(
      kind: CoreErrorKind.transport,
      message: 'the Rust core is not in this build',
    ),
  );

  @override
  Stream<CoreEvent> changes() => const Stream<CoreEvent>.empty();

  @override
  List<JournalEntry> journal() => const [];

  @override
  CoreStatus status() => const CoreStatus(registered: false, kid: '');
}

/// The core the app calls. `startup()` overrides it with the opened core; a test with a fake.
final notesCore = Provider<NotesCore>(
  (ref) => throw UnimplementedError(
    'Override notesCore (startup.dart does, with the opened core; a test passes a fake).',
  ),
);

/// The device key's identity as the core computes it: its kid and its thumbprint. `startup()` overrides it.
final deviceIdentity = Provider<DeviceIdentity>(
  (ref) => throw UnimplementedError(
    'Override deviceIdentity (startup.dart does, from the core; a test passes its own).',
  ),
);
