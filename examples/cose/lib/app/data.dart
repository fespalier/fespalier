import 'dart:async';

import 'package:cose_example/src/notes.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// The device's notes: a signed read.
///
/// `ref.serve` is the seam for reads. The call goes through `crateStackTransport` (the
/// `CoseTransport`, which seals it with the device key and opens the sealed answer); on an answer
/// the list is saved on the device with the time the server gave it, and only when the server
/// cannot be reached (`CrateStackOffline`: no network, or an answer that did not open) does the
/// page get that copy, marked `ServedFrom.local`. A refusal, a 401 included, is the answer: it is
/// never covered by the copy.
FutureOr<Served<List<Note>>> data(Ref ref) => ref.serve<List<Note>>(
  key: 'notes',
  codec: notesCodec,
  empty: () => const [],
  fetch: () async => notesFromWire(
    await ref
        .read(crateStackTransport)
        .send(const RpcCall(Ops.listNotes, <String, Object?>{})),
  ),
);
