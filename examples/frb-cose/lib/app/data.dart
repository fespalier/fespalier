import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:frb_cose_example/src/notes.dart';

/// The device's notes: a read through the core.
///
/// `ref.serve` is the seam for reads. The call goes through `crateStackTransport` (the `CoreTransport`, which the core
/// seals and opens); on an answer the list is saved on the device with the time the server gave it, and only when the
/// server cannot be reached (`CrateStackOffline`) does the page get that copy, marked `ServedFrom.local`. A refusal,
/// a 401 included, is the answer: it is never covered by the copy.
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
