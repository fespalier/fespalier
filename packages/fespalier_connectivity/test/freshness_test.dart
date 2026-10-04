// What a reconnect does to data with refetchOnReconnect, through fespalier's own freshData: loads again only when the
// value is at least staleTime old, and a flapping network loads once. The fake clock of testWidgets ages the value.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_connectivity/fespalier_connectivity.dart';
import 'package:fespalier_connectivity/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

var loads = 0;

const freshness = Freshness(
  staleTime: Duration(minutes: 1),
  refetchOnReconnect: true,
);

/// A data provider with the freshness above: a counter that goes up each time it loads.
final value = FutureProvider.autoDispose<int>(
  (ref) => freshData(ref, freshness, Future.value(++loads)),
);

/// The same without a staleTime: every reconnect loads again.
final always = FutureProvider.autoDispose<int>(
  (ref) => freshData(
    ref,
    const Freshness(refetchOnReconnect: true),
    Future.value(++loads),
  ),
);

({ProviderContainer container, FakeConnectivity fake}) start(
  FutureProvider<int> provider, {
  List<ConnectivityResult> now = wifi,
}) {
  final fake = FakeConnectivity(now: now);
  final container = ProviderContainer(
    overrides: [
      connectivitySource.overrideWithValue(fake),
      reconnectSignal.overrideWith(ConnectivitySignal.new),
    ],
  );
  addTearDown(container.dispose);
  container.listen(provider, (_, _) {});
  return (container: container, fake: fake);
}

/// A reload of a provider in a raw ProviderContainer starts on the container's scheduler (a zero-duration timer) and its
/// value arrives on the next: a millisecond of the fake clock, twice, is `pump()` for it.
Future<void> settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> end(WidgetTester tester, ProviderContainer container) async {
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  setUp(() => loads = 0);

  testWidgets('a reconnect within the staleTime loads nothing', (tester) async {
    final started = start(value);
    await settle(tester);
    expect(loads, 1);
    await tester.pump(const Duration(seconds: 20));
    started.fake.offline();
    started.fake.online();
    await settle(tester);
    expect(loads, 1);
    await end(tester, started.container);
  });

  testWidgets('a reconnect after the staleTime loads once', (tester) async {
    final started = start(value);
    await settle(tester);
    expect(loads, 1);
    await tester.pump(const Duration(minutes: 2));
    started.fake.offline();
    started.fake.online();
    await settle(tester);
    expect(loads, 2);
    expect(started.container.read(value).value, 2);
    await end(tester, started.container);
  });

  testWidgets(
    'a network that flaps loads once: a reload already under way is not repeated',
    (tester) async {
      final started = start(value);
      await settle(tester);
      await settle(tester);
      await tester.pump(const Duration(minutes: 2));
      started.fake.offline();
      started.fake.online();
      started.fake.offline();
      started.fake.online(ConnectivityResult.mobile);
      await settle(tester);
      await settle(tester);
      expect(loads, 2);
      await end(tester, started.container);
    },
  );

  testWidgets('a switch from Wi-Fi to mobile loads nothing, even long after', (
    tester,
  ) async {
    final started = start(value);
    await settle(tester);
    await tester.pump(const Duration(minutes: 5));
    started.fake.online(ConnectivityResult.mobile);
    await settle(tester);
    expect(loads, 1);
    await end(tester, started.container);
  });

  testWidgets('with no staleTime every reconnect loads', (tester) async {
    final started = start(always);
    await settle(tester);
    expect(loads, 1);
    started.fake.offline();
    started.fake.online();
    await settle(tester);
    expect(loads, 2);
    started.fake.offline();
    started.fake.online();
    await settle(tester);
    expect(loads, 3);
    await end(tester, started.container);
  });

  testWidgets(
    'without the override, reconnectSignal never fires and the platform is never asked',
    (tester) async {
      final fake = FakeConnectivity(now: none);
      final container = ProviderContainer(
        overrides: [connectivitySource.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);
      container.listen(value, (_, _) {});
      await settle(tester);
      await settle(tester);
      await tester.pump(const Duration(minutes: 2));
      fake.online();
      await settle(tester);
      expect(loads, 1);
      expect(fake.listenerCount, 0);
      await end(tester, container);
    },
  );

  testWidgets('a provider that is gone lets go of the platform', (
    tester,
  ) async {
    final started = start(value);
    await settle(tester);
    expect(started.fake.listenerCount, 1);
    started.container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
    expect(started.fake.listenerCount, 0);
  });
}
