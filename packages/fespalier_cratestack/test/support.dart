// What the tests share: a container with the package's overrides, a Ref to call `serve` with, and
// an intent to submit.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// A container wired with [crateStackTestOverrides] (and [extra]), disposed after the test.
ProviderContainer containerFor({
  CrateStackTransport? transport,
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

/// A [LocalStore] over [inner] whose every answer is a `Future`, like a store on a plugin: a read of
/// it is never synchronous, so an operation on it has awaits in the middle.
final class AsyncStore implements LocalStore {
  /// Wraps [inner].
  AsyncStore(this.inner);

  /// The store behind it, which a test reads directly.
  final InMemoryLocalStore inner;

  @override
  Future<String?> read(String key) async => inner.read(key);

  @override
  Future<void> write(String key, String value) async => inner.write(key, value);

  @override
  Future<void> writeAll(Map<String, String> entries) async =>
      inner.writeAll(entries);

  @override
  Future<void> delete(String key) async => inner.delete(key);

  @override
  Future<Iterable<String>> keys(String prefix) async => inner.keys(prefix);

  @override
  Future<void> clear(String prefix) async => inner.clear(prefix);
}
