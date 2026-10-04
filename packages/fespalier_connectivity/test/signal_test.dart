// ConnectivitySignal: it fires when the device goes from no network to a network, and at no other time.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_connectivity/fespalier_connectivity.dart';
import 'package:fespalier_connectivity/testing.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A container whose reconnectSignal is the package's, watched by [fires].
({ProviderContainer container, List<int> fires}) start(
  ConnectivitySource source,
) {
  final container = ProviderContainer(
    overrides: [
      connectivitySource.overrideWithValue(source),
      reconnectSignal.overrideWith(ConnectivitySignal.new),
    ],
  );
  addTearDown(container.dispose);
  final fires = <int>[];
  container.listen(reconnectSignal, (_, next) => fires.add(next));
  return (container: container, fires: fires);
}

Future<void> end(WidgetTester tester, ProviderContainer container) async {
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('the first answer is not a reconnect, whatever it is', (
    tester,
  ) async {
    for (final first in [wifi, none, mobile]) {
      final fake = FakeConnectivity(now: first);
      final started = start(fake);
      await tester.pump();
      expect(started.fires, isEmpty, reason: 'the first answer of $first');
      await end(tester, started.container);
    }
  });

  testWidgets('from no network to a network is one', (tester) async {
    final fake = FakeConnectivity(now: none);
    final started = start(fake);
    await tester.pump();
    expect(started.fires, isEmpty);
    fake.online();
    expect(started.fires, [1]);
    await end(tester, started.container);
  });

  testWidgets('from Wi-Fi to mobile, and back, is none', (tester) async {
    final fake = FakeConnectivity();
    final started = start(fake);
    await tester.pump();
    fake.online(ConnectivityResult.mobile);
    fake.online(ConnectivityResult.wifi);
    fake.set(const [ConnectivityResult.wifi, ConnectivityResult.vpn]);
    expect(started.fires, isEmpty);
    await end(tester, started.container);
  });

  testWidgets('going offline is none, and each return after it is one', (
    tester,
  ) async {
    final fake = FakeConnectivity();
    final started = start(fake);
    await tester.pump();
    fake.offline();
    expect(
      started.fires,
      isEmpty,
      reason: 'losing the network is not a reconnect',
    );
    fake.online();
    expect(started.fires, [1]);
    fake.offline();
    fake.online(ConnectivityResult.mobile);
    expect(started.fires, [1, 2]);
    await end(tester, started.container);
  });

  testWidgets(
    'a late first answer after an offline event is a reconnect only if it is a network',
    (tester) async {
      final source = ScriptedSource();
      final started = start(source);
      source.controller.add(none); // the event came first
      source.answers.single.complete(wifi); // an older answer: ignored
      await tester.pump();
      expect(started.fires, isEmpty);
      expect(started.container.read(networkConnectivity), none);
      source.controller.add(wifi);
      expect(started.fires, [1]);
      await end(tester, started.container);
    },
  );

  testWidgets(
    'a resume that finds the network back (iOS dropped the event) is a reconnect',
    (tester) async {
      final fake = FakeConnectivity();
      final started = start(fake);
      await tester.pump();
      fake.offline();
      // The device is online again, but the app was in the background and never heard it.
      fake.now = wifi;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(started.fires, [1]);
      await end(tester, started.container);
    },
  );

  testWidgets(
    'with nothing listening to reconnectSignal there is no source subscription at all',
    (tester) async {
      final fake = FakeConnectivity();
      final container = ProviderContainer(
        overrides: [
          connectivitySource.overrideWithValue(fake),
          reconnectSignal.overrideWith(ConnectivitySignal.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pump(const Duration(milliseconds: 1));
      expect(fake.listenerCount, 0);
      expect(fake.checks, 0);

      final sub = container.listen(reconnectSignal, (_, _) {});
      expect(fake.listenerCount, 1);
      sub.close();
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        fake.listenerCount,
        0,
        reason: 'the last listener of the signal let go of the platform',
      );
      await end(tester, container);
    },
  );

  testWidgets(
    'a banner that watches hasNetwork keeps the subscription the signal opened',
    (tester) async {
      final fake = FakeConnectivity();
      final started = start(fake);
      final banner = started.container.listen(hasNetwork, (_, _) {});
      await tester.pump();
      expect(
        fake.listenerCount,
        1,
        reason: 'one subscription for the signal and the banner',
      );
      banner.close();
      await tester.pump(const Duration(milliseconds: 1));
      expect(fake.listenerCount, 1, reason: 'the signal is still watched');
      await end(tester, started.container);
      expect(fake.listenerCount, 0);
    },
  );
}
