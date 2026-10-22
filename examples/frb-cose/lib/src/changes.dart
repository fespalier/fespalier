import 'package:fespalier_frb/fespalier_frb.dart';

import 'core.dart';

/// The core's events, as a feed: one subscription, held by Riverpod (`fespalier_frb`).
///
/// `/core` watches `coreChanges.any`, so every event the core emits (a call, a registration, a forgotten key) rebuilds
/// that page, and nothing else listens. The stream is opened once per container, and a `ref.watch` inside it reopens
/// it when the core is replaced.
final coreChanges = ChangeFeed<CoreEvent>(
  (ref) => ref.watch(notesCore).changes(),
  name: 'frb_cose.core',
);
