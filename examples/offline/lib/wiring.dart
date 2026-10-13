import 'package:fespalier/startup.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:offline/demo/demo_server.dart';
import 'package:offline/errors.dart';
import 'package:offline/network.dart';
import 'package:offline/note_sync.dart';
import 'package:offline/session.dart';
import 'package:fespalier/fespalier.dart';

/// The backend behind the "network" switch. The demo server here; a real app overrides
/// `crateStackTransport` with a transport over its generated client (and Dio) instead of this whole file.
final shopServer = Provider<CrateStackTransport>(
  (ref) => ref.watch(demoServer),
);

/// What connects fespalier_cratestack to this app: the seams, once.
///
/// - the transport (through the switch) and the error reader that classifies what it throws,
/// - whose data it is (`crateStackScope`), which a sign-out wipes,
/// - the collections every sync pulls.
///
/// Not here: `localStore`, which stays the in-memory default (a queued intent is lost when the app
/// exits; a device build overrides it with `HiveLocalStore`, see the README), and the triggers, which
/// startup() and the tests each choose.
List<Override> appWiring() => [
  crateStackTransport.overrideWith(
    (ref) =>
        SwitchedTransport(ref.watch(shopServer), () => ref.read(networkOnline)),
  ),
  crateStackErrors.overrideWithValue(shopErrors),
  crateStackScope.overrideWith((ref) => ref.watch(accountId)),
  syncCollections.overrideWithValue(const ['notes']),
];

/// The `RowSync` that moves notes over the same transport. Apart from [appWiring] so that a test can put the
/// package's `FakeRowServer` in its place (a provider can only be overridden once per container).
Override noteRowSync() =>
    rowSync.overrideWith((ref) => NoteSync(ref.watch(crateStackTransport)));
