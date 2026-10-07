// What the tests share: a container with the package's overrides, a Ref to call `serve` with, and
// an intent to submit.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// A container wired with [crateStackTestOverrides] (and [extra]), disposed after the test.
ProviderContainer containerFor({
  FakeCrateStackTransport? transport,
  LocalStore? store,
  String? scope = 'u1',
  SyncTriggers triggers = const SyncTriggers(),
  RowSync? rowServer,
  List<String> collections = const [],
  List<Override> extra = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      ...crateStackTestOverrides(
        transport: transport,
        store: store,
        scope: scope,
        triggers: triggers,
        rowServer: rowServer,
        collections: collections,
      ),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The one provider whose value is its own [Ref], to call a `Ref` extension from a test.
final refProvider = Provider<Ref>((ref) => ref);

/// Submits a cancel of order [id] on [queue].
Future<IntentOutcome<Object?>> submitCancel(
  IntentQueue queue, {
  String op = 'cancelOrder',
  int id = 42,
  String? subject,
  Set<String> touches = const {'orders'},
  Object? input,
}) => queue.submit<Object?>(
  RpcCall(op, input ?? {'id': id}),
  subject: subject ?? 'order:$id',
  touches: touches,
  decode: (output) => output,
);

/// The instant the tests start from.
final epoch = DateTime.utc(2026, 3, 1, 10);
