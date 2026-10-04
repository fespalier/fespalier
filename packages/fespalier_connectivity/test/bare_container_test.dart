// This file has no testWidgets, so no WidgetsBinding exists: appResumeSignal cannot be built (its AppLifecycleListener
// needs one). networkConnectivity listens to it for the iOS resume repair, and that must not be an error here.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_connectivity/fespalier_connectivity.dart';
import 'package:fespalier_connectivity/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('there is no binding in this file: appResumeSignal cannot be built', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      () => container.listen(appResumeSignal, (_, _) {}, onError: (_, _) {}),
      returnsNormally,
      reason: 'listen() hands the build error to onError',
    );
    expect(() => container.read(appResumeSignal), throwsA(anything));
  });

  test(
    'a bare ProviderContainer builds networkConnectivity without throwing, and it works',
    () async {
      final fake = FakeConnectivity(now: none);
      final container = ProviderContainer(
        overrides: [connectivitySource.overrideWithValue(fake)],
      );
      final sub = container.listen(networkConnectivity, (_, _) {});
      await turn();
      expect(sub.read(), none);
      fake.online();
      expect(sub.read(), wifi);
      container.dispose();
      expect(fake.listenerCount, 0);
    },
  );

  test('ConnectivitySignal works in it too', () async {
    final fake = FakeConnectivity(now: none);
    final container = ProviderContainer(
      overrides: [
        connectivitySource.overrideWithValue(fake),
        reconnectSignal.overrideWith(ConnectivitySignal.new),
      ],
    );
    addTearDown(container.dispose);
    final fires = <int>[];
    container.listen(reconnectSignal, (_, next) => fires.add(next));
    await turn();
    fake.online();
    expect(fires, [1]);
  });
}
