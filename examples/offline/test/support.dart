import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline/app.g.dart';
import 'package:offline/network.dart';
import 'package:offline/wiring.dart';

/// The notes' server behind the app bar's switch, as the demo's `NoteSync` is (it sends over the switched transport).
/// The server itself stays reachable, so a second phone in a test can still use it.
class _SwitchedRows implements RowSync {
  _SwitchedRows(this._rows, this._online);

  final FakeRowServer _rows;
  final bool Function() _online;

  @override
  Future<PushResult> push(List<OwnedRow> dirty) =>
      _online() ? _rows.push(dirty) : throw const Unreachable();

  @override
  Future<PullPage> pull(String collection, String? cursor) =>
      _online() ? _rows.pull(collection, cursor) : throw const Unreachable();
}

class _StartsOffline extends NetworkSwitch {
  @override
  bool build() => false;
}

/// The package's fakes standing where the demo server and its `RowSync` stand in the app: the same
/// wiring (`appWiring()`), with a server the test scripts.
class Harness {
  Harness({this.startOffline = false}) {
    // The orders of a shop that has one that can still be cancelled, and one already shipped.
    orders = [
      {'id': 1, 'item': 'Ceramic mug', 'status': 'placed', 'version': 1},
      {'id': 3, 'item': 'Cast-iron pan', 'status': 'shipped', 'version': 1},
    ];
    transport
      ..on('listOrders', (_) => [for (final o in orders) Map.of(o)])
      ..on('cancelOrder', (input) {
        final id = (input! as Map<String, Object?>)['id'];
        final order = orders.firstWhere((o) => o['id'] == id);
        order
          ..['status'] = 'cancelled'
          ..['version'] = (order['version']! as int) + 1;
        return Map.of(order);
      });
  }

  final bool startOffline;

  /// The shop: the idempotency layer, with a script per operation.
  final transport = FakeCrateStackTransport();

  /// The server of the notes, which merges per field.
  final rows = FakeRowServer();

  /// What the device keeps: shared, so a test can read what a sign-out wiped.
  final store = InMemoryLocalStore();

  late final List<Map<String, Object?>> orders;

  List<Override> get overrides => [
    // crateStackTestOverrides(...) overrides the transport, the scope and the row sync too, which appWiring()
    // does: a provider cannot be overridden twice in one container, so the two it does not repeat are here.
    // A synchronous in-memory store, and no lifecycle trigger (a bare container has no WidgetsBinding).
    localStore.overrideWithValue(store),
    appResumeSignal.overrideWith(RefetchSignal.new),
    // The app's own wiring: the switch, the error reader, the account, the row sync.
    ...appWiring(),
    shopServer.overrideWithValue(transport),
    rowSync.overrideWith(
      (ref) => _SwitchedRows(rows, () => ref.read(networkOnline)),
    ),
    // The app's tick, fired by hand: the app's own timer would leave one pending.
    syncTicker.overrideWith(ManualSyncTicker.new),
    if (startOffline) networkOnline.overrideWith(_StartsOffline.new),
  ];

  /// Every send of [op] the shop saw, with its idempotency key, including those that failed or replayed.
  Iterable<RecordedCall> sent(String op) => transport.calls.where(
    (c) => c.call is RpcCall && (c.call as RpcCall).opId == op,
  );

  /// Opens [location] with the whole app around it.
  Future<ProviderContainer> open(
    WidgetTester tester, [
    String location = '/orders',
  ]) => pumpRouter(
    tester,
    AppRoutes.router(initialLocation: location),
    overrides: overrides,
  );

  /// The app bar's switch, as a person flips it.
  Future<void> setNetwork(WidgetTester tester, {required bool online}) async {
    final switcher = tester.widget<Switch>(
      find.byKey(const Key('network-switch')),
    );
    if (switcher.value != online) {
      await tester.tap(find.byKey(const Key('network-switch')));
    }
    await tester.pumpAndSettle();
  }
}

/// The app tick, fired by hand.
void tick(ProviderContainer container) =>
    (container.read(syncTicker.notifier) as ManualSyncTicker).tick();
