import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_cratestack/fespalier_cratestack.dart';

import 'core.dart';
import 'core_transport.dart';

/// What `startup()` returns with a core: the core, the device key's identity, the transport over the core, and the
/// account the notes belong to (the device key's thumbprint). A test passes a fake core to the same list.
List<Override> coreOverrides({
  required NotesCore core,
  required DeviceIdentity identity,
}) => [
  notesCore.overrideWithValue(core),
  deviceIdentity.overrideWithValue(identity),
  crateStackTransport.overrideWith(
    (ref) => CoreTransport(ref.watch(notesCore)),
  ),
  crateStackScope.overrideWithValue(identity.thumbprint),
];

/// What `startup()` returns on the web, where the core is left out: no core, no account (so nothing is saved), and a
/// transport over the unavailable core, which answers every call as offline without sending anything.
List<Override> unavailableOverrides() => [
  notesCore.overrideWithValue(const UnavailableCore()),
  deviceIdentity.overrideWithValue(
    const DeviceIdentity(kid: '', thumbprint: ''),
  ),
  crateStackTransport.overrideWith(
    (ref) => CoreTransport(ref.watch(notesCore)),
  ),
];
