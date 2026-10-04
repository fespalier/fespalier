// networkConnectivity and hasNetwork on a ProviderContainer, over a FakeConnectivity. A raw ProviderContainer disposes
// what nothing listens to on a zero-duration timer, so a test under testWidgets pumps a millisecond before it ends.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_connectivity/fespalier_connectivity.dart';
import 'package:fespalier_connectivity/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

ProviderContainer containerOf(ConnectivitySource source) {
  final container = ProviderContainer(
    overrides: [connectivitySource.overrideWithValue(source)],
  );
  addTearDown(container.dispose);
  return container;
}

/// Ends a test that used a raw container: disposes it and lets its timer fire.
Future<void> end(WidgetTester tester, ProviderContainer container) async {
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  group('hasNetwork', () {
    testWidgets(
      'is true before any answer, so nothing flashes offline at start',
      (tester) async {
        final fake = FakeConnectivity(now: none);
        final container = containerOf(fake);
        final sub = container.listen(hasNetwork, (_, _) {});
        expect(sub.read(), isTrue);
        expect(container.read(networkConnectivity), isNull);
        await tester.pump(); // the answer of check()
        expect(sub.read(), isFalse);
        await end(tester, container);
      },
    );

    testWidgets('follows [none] and anything else', (tester) async {
      final fake = FakeConnectivity();
      final container = containerOf(fake);
      final seen = <bool>[];
      container.listen(hasNetwork, (_, next) => seen.add(next));
      await tester.pump();
      fake.offline();
      expect(container.read(hasNetwork), isFalse);
      fake.online();
      expect(container.read(hasNetwork), isTrue);
      fake.set(const [ConnectivityResult.wifi, ConnectivityResult.vpn]);
      expect(container.read(hasNetwork), isTrue);
      fake.set(const [ConnectivityResult.none]);
      // A provider derived from another is recomputed on the container's scheduler: a zero-duration timer.
      await tester.pump(const Duration(milliseconds: 1));
      expect(seen, [false, true, false]);
      await end(tester, container);
    });
  });

  group('networkConnectivity', () {
    testWidgets(
      'nothing is sent on listen: the first state is the answer of check()',
      (tester) async {
        final fake = FakeConnectivity(now: mobile);
        final container = containerOf(fake);
        final sub = container.listen(networkConnectivity, (_, _) {});
        expect(sub.read(), isNull);
        expect(fake.checks, 1);
        await tester.pump();
        expect(sub.read(), mobile);
        await end(tester, container);
      },
    );

    testWidgets(
      'an event that arrives before a late check() answer wins over it',
      (tester) async {
        final source = ScriptedSource();
        final container = containerOf(source);
        final sub = container.listen(networkConnectivity, (_, _) {});
        source.controller.add(wifi);
        expect(sub.read(), wifi);
        source.answers.single.complete(
          none,
        ); // the late answer is older than the event
        await tester.pump();
        expect(sub.read(), wifi);
        await end(tester, container);
      },
    );

    testWidgets('a late answer applies when no event came', (tester) async {
      final source = ScriptedSource();
      final container = containerOf(source);
      final sub = container.listen(networkConnectivity, (_, _) {});
      source.answers.single.complete(none);
      await tester.pump();
      expect(sub.read(), none);
      await end(tester, container);
    });

    testWidgets('equal lists do not notify', (tester) async {
      final fake = FakeConnectivity();
      final container = containerOf(fake);
      final seen = <List<ConnectivityResult>?>[];
      container.listen(networkConnectivity, (_, next) => seen.add(next));
      await tester.pump();
      expect(seen, [wifi], reason: 'the first answer');
      fake.online();
      fake.set([ConnectivityResult.wifi]);
      await tester.pump();
      expect(seen, hasLength(1));
      fake.online(ConnectivityResult.mobile);
      expect(seen, hasLength(2));
      await end(tester, container);
    });

    testWidgets(
      'the state is read-only: a source cannot change it afterwards',
      (tester) async {
        final fake = FakeConnectivity();
        final container = containerOf(fake);
        final sub = container.listen(networkConnectivity, (_, _) {});
        final list = [ConnectivityResult.wifi];
        fake.set(list);
        list[0] = ConnectivityResult.none;
        expect(sub.read(), wifi);
        expect(
          () => sub.read()!.add(ConnectivityResult.none),
          throwsUnsupportedError,
        );
        await end(tester, container);
      },
    );

    testWidgets(
      'one subscription for three watchers, none after the last closes',
      (tester) async {
        final fake = FakeConnectivity();
        final container = containerOf(fake);
        final a = container.listen(networkConnectivity, (_, _) {});
        final b = container.listen(hasNetwork, (_, _) {});
        final c = container.listen(networkConnectivity, (_, _) {});
        expect(fake.listenerCount, 1);
        a.close();
        b.close();
        await tester.pump(const Duration(milliseconds: 1));
        expect(fake.listenerCount, 1, reason: 'one watcher is left');
        c.close();
        await tester.pump(const Duration(milliseconds: 1));
        expect(fake.listenerCount, 0);
        await end(tester, container);
      },
    );

    testWidgets('a resume asks check() once and applies the answer', (
      tester,
    ) async {
      final fake = FakeConnectivity();
      final container = containerOf(fake);
      final sub = container.listen(networkConnectivity, (_, _) {});
      await tester.pump();
      expect(sub.read(), wifi);
      expect(fake.checks, 1);

      // iOS dropped the event while the app was in the background: the device is offline and the state says Wi-Fi.
      fake.now = none;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(fake.checks, 2);
      expect(sub.read(), none);
      expect(container.read(hasNetwork), isFalse);
      await end(tester, container);
    });

    testWidgets('a resume does not ask while nothing watches', (tester) async {
      final fake = FakeConnectivity();
      final container = containerOf(fake);
      container.listen(networkConnectivity, (_, _) {}).close();
      await tester.pump(const Duration(milliseconds: 1));
      final before = fake.checks;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(fake.checks, before);
      await end(tester, container);
    });

    testWidgets(
      'a stream error is C1, a failing check() is C2, and the state is kept',
      (tester) async {
        final source = ScriptedSource();
        final container = containerOf(source);
        final sub = container.listen(networkConnectivity, (_, _) {});
        source.controller.add(wifi);
        final lines = await printed(() async {
          source.controller.addError(StateError('stream broke'));
          source.answers.single.completeError(StateError('check broke'));
          await tester.pump();
        });
        expect(lines, [
          'fespalier_connectivity: the connectivity stream reported an error: Bad state: stream broke',
          'fespalier_connectivity: checking connectivity failed: Bad state: check broke',
        ]);
        expect(sub.read(), wifi, reason: 'an error changes nothing');
        source.controller.add(mobile);
        expect(sub.read(), mobile, reason: 'the subscription stays');
        await end(tester, container);
      },
    );

    testWidgets(
      'a check() that throws at once is C2, and a changes getter that throws is C1',
      (tester) async {
        final source = ScriptedSource()
          ..checkThrows = StateError('no platform')
          ..changesThrows = StateError('no channel');
        final container = containerOf(source);
        late ProviderSubscription<List<ConnectivityResult>?> sub;
        final lines = await printed(() async {
          sub = container.listen(networkConnectivity, (_, _) {});
          await tester.pump();
        });
        expect(lines, [
          'fespalier_connectivity: the connectivity stream reported an error: Bad state: no channel',
          'fespalier_connectivity: checking connectivity failed: Bad state: no platform',
        ]);
        expect(sub.read(), isNull);
        expect(
          container.read(hasNetwork),
          isTrue,
          reason: 'unknown is not offline',
        );
        await end(tester, container);
      },
    );
  });

  group('without an override of connectivitySource', () {
    testWidgets(
      'a widget test reaches the plugin: Flutter reports C3, and check() fails with C2',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final reports = <FlutterErrorDetails>[];
        final original = FlutterError.onError;
        FlutterError.onError = reports.add;
        late List<String> lines;
        try {
          lines = await printed(() async {
            container.listen(hasNetwork, (_, _) {});
            // A platform channel answers on the real event loop, which a widget test's fake one never reaches.
            await tester.runAsync(() async {
              for (var turns = 0; turns < 1000 && reports.isEmpty; turns++) {
                await turn();
              }
            });
            await tester.pump();
          });
        } finally {
          FlutterError.onError = original;
        }
        expect(reports, hasLength(1));
        expect(reports.single.library, 'services library');
        expect(
          reports.single.context!.toDescription(),
          'while activating platform stream on channel dev.fluttercommunity.plus/connectivity_status',
        );
        expect(
          reports.single.exception.toString(),
          'MissingPluginException(No implementation found for method listen on channel dev.fluttercommunity.plus/connectivity_status)',
        );
        expect(lines, [
          'fespalier_connectivity: checking connectivity failed: MissingPluginException(No implementation found for method check on channel dev.fluttercommunity.plus/connectivity)',
        ]);
        expect(
          container.read(hasNetwork),
          isTrue,
          reason: 'unknown is not offline',
        );
        await end(tester, container);
      },
    );
  });

  group('FakeConnectivity', () {
    test(
      'delivers a change to every listener before set() returns, and sends nothing on listen',
      () async {
        final fake = FakeConnectivity();
        final first = <List<ConnectivityResult>>[];
        final second = <List<ConnectivityResult>>[];
        final a = fake.changes.listen(first.add);
        final b = fake.changes.listen(second.add);
        expect(first, isEmpty);
        expect(fake.listenerCount, 2);
        fake.offline();
        expect(first, [none]);
        expect(second, [none]);
        fake.online(ConnectivityResult.ethernet);
        expect(first.last, const [ConnectivityResult.ethernet]);
        expect(fake.now, const [ConnectivityResult.ethernet]);
        await a.cancel();
        expect(fake.listenerCount, 1);
        await b.cancel();
        expect(fake.listenerCount, 0);
      },
    );

    test('check() answers now and counts', () async {
      final fake = FakeConnectivity(now: mobile);
      expect(await fake.check(), mobile);
      fake.now = none;
      expect(await fake.check(), none);
      expect(fake.checks, 2);
    });

    test('is Wi-Fi by default', () async {
      expect(await FakeConnectivity().check(), wifi);
    });
  });
}
