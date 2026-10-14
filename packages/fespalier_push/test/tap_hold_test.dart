// A tap while the app starts (since 0.16.0). `launch()` runs before `runApp`, and `attach` runs
// after startup(), ready() and the first frame of the router, so a tap in between used to be lost:
// `taps` is a broadcast stream, and nobody listened yet. The adapter keeps the latest one from
// `launch()` on, and opens it once, when `attach` subscribes. The cold-start notification, which
// `launch()` already opened, is not opened a second time when the stream says it again.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_push/fespalier_adapter.dart';
import 'package:fespalier_push/fespalier_push.dart';
import 'package:fespalier_push/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PushTarget? _route(PushMessage m) {
  final link = m.data['link'];
  if (link is! String) return null;
  return PushTarget(link);
}

GoRouter _router() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const Text('home')),
    GoRoute(path: '/a', builder: (_, _) => const Text('a')),
    GoRoute(path: '/b', builder: (_, _) => const Text('b')),
    GoRoute(path: '/c', builder: (_, _) => const Text('c')),
  ],
);

/// A source that counts the live subscriptions to `taps`, as a plugin's native side would.
final class _Counting extends FakePushSource {
  _Counting();

  int live = 0;
  int opened = 0;

  @override
  Stream<PushMessage> get taps => Stream<PushMessage>.multi((controller) {
    live++;
    opened++;
    final subscription = super.taps.listen(controller.add);
    controller.onCancel = () {
      live--;
      return subscription.cancel();
    };
  }, isBroadcast: true);
}

/// A source whose `taps` cannot be read.
final class _NoTaps extends FakePushSource {
  @override
  Stream<PushMessage> get taps => throw StateError('no tap channel');
}

void main() {
  late List<FlutterErrorDetails> reported;
  late RecordingTelemetry rec;
  late ProviderContainer container;
  late GoRouter router;

  void captureReports() {
    final original = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = original);
  }

  setUp(() {
    FespalierPush.debugReset();
    reported = [];
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
  });
  tearDown(() {
    FespalierTelemetry.install(null);
    FespalierPush.debugReset();
  });

  /// What `AppMain` does around the adapter: `launch()` before `runApp`, then (later) the
  /// router is shown and `attach` is called with the scope's container.
  Future<void> boot(WidgetTester tester) async {
    router = _router();
    addTearDown(router.dispose);
    container = ProviderContainer(overrides: adapter.overrides());
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
  }

  String here() => router.routerDelegate.currentConfiguration.uri.toString();
  int opens() => rec.log.where((l) => l.contains('start custom')).length;

  testWidgets('a tap during startup opens once, after attach', (tester) async {
    final source = FakePushSource();
    FespalierPush.configure(source: source, route: _route);
    expect(adapter.launch(), isNull);

    // startup() is running: no router, no container, nobody on `taps` but the adapter.
    source.tap(const PushMessage(id: 't1', data: {'link': '/a'}));
    await tester.pump();

    await boot(tester);
    expect(here(), '/');
    adapter.attach(router, container);
    await tester.pumpAndSettle();
    expect(here(), '/a');
    expect(opens(), 1);

    // It was delivered, not kept: nothing opens it again.
    router.go('/');
    await tester.pumpAndSettle();
    await tester.pump();
    expect(here(), '/');
    expect(opens(), 1);
  });

  testWidgets('only the latest tap during startup opens', (tester) async {
    final source = FakePushSource();
    FespalierPush.configure(source: source, route: _route);
    adapter.launch();

    source.tap(const PushMessage(id: 'first', data: {'link': '/a'}));
    await tester.pump();
    source.tap(const PushMessage(id: 'second', data: {'link': '/b'}));
    await tester.pump();
    source.tap(const PushMessage(id: 'third', data: {'link': '/c'}));
    await tester.pump();

    await boot(tester);
    adapter.attach(router, container);
    await tester.pumpAndSettle();
    expect(here(), '/c');
    expect(opens(), 1);
  });

  testWidgets('a tap after attach opens as before, and the hold is gone', (
    tester,
  ) async {
    final source = _Counting();
    FespalierPush.configure(source: source, route: _route);
    adapter.launch();
    expect(source.live, 1, reason: 'the hold between launch() and attach');

    await boot(tester);
    adapter.attach(router, container);
    await tester.pump();
    // The scope's own subscription took over: one, not two.
    expect(source.live, 1);
    source.tap(const PushMessage(id: 'warm', data: {'link': '/b'}));
    await tester.pumpAndSettle();
    expect(here(), '/b');
    expect(opens(), 1);

    container.dispose();
    await tester.pump();
    expect(source.live, 0);
  });

  testWidgets('a hold that attach never ends goes with a new configure', (
    tester,
  ) async {
    final source = _Counting();
    FespalierPush.configure(source: source, route: _route);
    adapter.launch();
    source.tap(const PushMessage(id: 'old', data: {'link': '/a'}));
    await tester.pump();
    expect(source.live, 1);

    final other = FakePushSource();
    FespalierPush.configure(source: other, route: _route);
    await tester.pump();
    expect(source.live, 0);

    await boot(tester);
    adapter.attach(router, container);
    await tester.pumpAndSettle();
    expect(here(), '/', reason: 'a tap of the old configuration is not kept');
    expect(opens(), 0);
  });

  group('the cold-start notification', () {
    const cold = PushMessage(id: 'cold', data: {'link': '/a'});

    testWidgets('seen again on taps before attach is not opened twice', (
      tester,
    ) async {
      final source = FakePushSource(initial: cold);
      FespalierPush.configure(source: source, route: _route);
      final launch = adapter.launch() as InboundLaunch?;
      expect(launch?.location, '/a');
      expect(opens(), 1);

      // The same notification on the stream, as some Android plugins deliver it.
      source.tap(cold);
      await tester.pump();

      await boot(tester);
      adapter.attach(router, container);
      await tester.pumpAndSettle();
      // launch() opened it (the router is built at the launch location in an app); the stream
      // copy opens nothing, and is not counted as a second navigation.
      expect(here(), '/');
      expect(opens(), 1);

      // Once: the next tap with that id is a new notification.
      source.tap(cold);
      await tester.pumpAndSettle();
      expect(here(), '/a');
      expect(opens(), 2);
    });

    testWidgets('another tap during startup still opens', (tester) async {
      final source = FakePushSource(initial: cold);
      FespalierPush.configure(source: source, route: _route);
      adapter.launch();
      source.tap(const PushMessage(id: 'other', data: {'link': '/b'}));
      await tester.pump();

      await boot(tester);
      adapter.attach(router, container);
      await tester.pumpAndSettle();
      expect(here(), '/b');
      expect(opens(), 2);
    });

    testWidgets(
      'without an id, the same payload on the stream is the same tap',
      (tester) async {
        const idless = PushMessage(data: {'link': '/a', 'n': 1});
        final source = FakePushSource(initial: idless);
        FespalierPush.configure(source: source, route: _route);
        adapter.launch();
        source.tap(const PushMessage(data: {'link': '/a', 'n': 1}));
        await tester.pump();

        await boot(tester);
        adapter.attach(router, container);
        await tester.pumpAndSettle();
        expect(here(), '/');
        expect(opens(), 1);
      },
    );

    testWidgets('without an id, another payload on the stream opens', (
      tester,
    ) async {
      final source = FakePushSource(
        initial: const PushMessage(data: {'link': '/a'}),
      );
      FespalierPush.configure(source: source, route: _route);
      adapter.launch();
      source.tap(const PushMessage(data: {'link': '/b'}));
      await tester.pump();

      await boot(tester);
      adapter.attach(router, container);
      await tester.pumpAndSettle();
      expect(here(), '/b');
    });
  });

  group('when the source misbehaves', () {
    testWidgets('a stream error during startup is reported once', (
      tester,
    ) async {
      captureReports();
      final source = FakePushSource();
      FespalierPush.configure(source: source, route: _route);
      adapter.launch();
      source.tapError(StateError('plugin'));
      await tester.pump();
      expect(reported.map((d) => '${d.exception}'), [contains('plugin')]);

      await boot(tester);
      adapter.attach(router, container);
      await tester.pumpAndSettle();
      expect(reported, hasLength(1));
      expect(here(), '/');
    });

    testWidgets('taps that cannot be read are reported, and nothing else is', (
      tester,
    ) async {
      captureReports();
      FespalierPush.configure(
        source: _NoTaps(),
        route: _route,
        onToken: (_) {},
      );
      expect(adapter.launch(), isNull);
      expect(reported, isNotEmpty);
      expect('${reported.first.exception}', contains('no tap channel'));
    });
  });
}
