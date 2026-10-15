// An action while the app starts (since 0.18.0). `launch()` runs before `runApp`, and `attach` runs
// after startup(), ready() and the first frame of the router, so an action in between used to be
// lost: a source's `actions` is a broadcast stream, and nobody listened yet. The adapter keeps the
// latest action across the sources from `launch()` on, and opens it once, when `attach` subscribes.
// The cold-start action, which `launch()` already opened, is not opened a second time when the
// stream says it again during startup.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_launch/fespalier_adapter.dart';
import 'package:fespalier_launch/fespalier_launch.dart';
import 'package:fespalier_launch/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

LaunchTarget? _route(LaunchAction action) => switch (action) {
  ShortcutAction(type: 'a') => LaunchTarget('/a'),
  ShortcutAction(type: 'b') => LaunchTarget('/b'),
  ShortcutAction(type: 'c') => LaunchTarget('/c'),
  ShortcutAction() => null,
  WidgetAction(uri: final uri) => LaunchTarget(uri.path),
};

GoRouter _router() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const Text('home')),
    GoRoute(path: '/a', builder: (_, _) => const Text('a')),
    GoRoute(path: '/b', builder: (_, _) => const Text('b')),
    GoRoute(path: '/c', builder: (_, _) => const Text('c')),
  ],
);

/// A source that counts the live subscriptions to `actions`, as a plugin's native side would.
final class _Counting extends FakeLaunchSource {
  int live = 0;

  @override
  Stream<LaunchAction> get actions => Stream<LaunchAction>.multi((controller) {
    live++;
    final subscription = super.actions.listen(
      controller.add,
      onError: controller.addError,
    );
    controller.onCancel = () {
      live--;
      return subscription.cancel();
    };
  }, isBroadcast: true);
}

/// A source whose `actions` cannot be read.
final class _NoActions extends FakeLaunchSource {
  @override
  Stream<LaunchAction> get actions => throw StateError('no action channel');
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
    FespalierLaunch.debugReset();
    reported = [];
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
  });
  tearDown(() {
    FespalierTelemetry.install(null);
    FespalierLaunch.debugReset();
  });

  /// What `AppMain` does around the adapter: `launch()` before `runApp`, then (later) the
  /// router is shown and `attach` is called with the scope's container.
  Future<void> boot(WidgetTester tester) async {
    router = _router();
    addTearDown(router.dispose);
    container = ProviderContainer();
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

  testWidgets('an action during startup opens once, after attach', (
    tester,
  ) async {
    final source = FakeLaunchSource();
    FespalierLaunch.configure(sources: [source], route: _route);
    expect(adapter.launch(), isNull);

    // startup() is running: no router, no container, nobody on `actions` but the adapter.
    source.shortcut('a');
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

  testWidgets('only the latest action during startup opens, across sources', (
    tester,
  ) async {
    final first = FakeLaunchSource();
    final second = FakeLaunchSource();
    addTearDown(first.close);
    addTearDown(second.close);
    FespalierLaunch.configure(sources: [first, second], route: _route);
    adapter.launch();

    first.shortcut('a');
    await tester.pump();
    second.shortcut('b');
    await tester.pump();
    first.shortcut('c');
    await tester.pump();

    await boot(tester);
    adapter.attach(router, container);
    await tester.pumpAndSettle();
    expect(here(), '/c');
    expect(opens(), 1);
  });

  testWidgets('the hold is one listener, and the scope\'s takes its place', (
    tester,
  ) async {
    final source = _Counting();
    addTearDown(source.close);
    FespalierLaunch.configure(sources: [source], route: _route);
    adapter.launch();
    expect(source.live, 1, reason: 'the hold between launch() and attach');

    await boot(tester);
    adapter.attach(router, container);
    await tester.pump();
    // The scope's own subscription took over: one, not two.
    expect(source.live, 1);
    source.shortcut('a');
    await tester.pumpAndSettle();
    expect(here(), '/a');
    expect(opens(), 1);

    container.dispose();
    await tester.pump();
    expect(source.live, 0);
  });

  testWidgets('a hold that attach never ends goes with a new configure', (
    tester,
  ) async {
    final source = _Counting();
    addTearDown(source.close);
    FespalierLaunch.configure(sources: [source], route: _route);
    adapter.launch();
    source.shortcut('b');
    await tester.pump();
    expect(source.live, 1);

    final other = FakeLaunchSource();
    addTearDown(other.close);
    FespalierLaunch.configure(sources: [other], route: _route);
    await tester.pump();
    expect(source.live, 0);

    await boot(tester);
    adapter.attach(router, container);
    await tester.pumpAndSettle();
    expect(
      here(),
      '/',
      reason: 'an action of the old configuration is not kept',
    );
    expect(opens(), 0);
  });

  group('the cold-start action', () {
    const cold = ShortcutAction('a');

    testWidgets('said again on the stream before attach is not opened twice', (
      tester,
    ) async {
      final source = FakeLaunchSource(initial: cold);
      addTearDown(source.close);
      FespalierLaunch.configure(sources: [source], route: _route);
      final launch = adapter.launch() as InboundLaunch?;
      expect(launch?.location, '/a');
      expect(opens(), 1);

      // The same action on the stream, as some plugins deliver it.
      source.act(cold);
      await tester.pump();

      await boot(tester);
      adapter.attach(router, container);
      await tester.pumpAndSettle();
      // launch() opened it (the router is built at the launch location in an app); the stream
      // copy opens nothing.
      expect(here(), '/');
      expect(opens(), 1);

      // Once: an equal action after attach is a new one.
      source.act(cold);
      await tester.pumpAndSettle();
      expect(here(), '/a');
      expect(opens(), 2);
    });

    testWidgets('another action during startup still opens', (tester) async {
      final source = FakeLaunchSource(initial: cold);
      addTearDown(source.close);
      FespalierLaunch.configure(sources: [source], route: _route);
      adapter.launch();
      source.shortcut('b');
      await tester.pump();

      await boot(tester);
      adapter.attach(router, container);
      await tester.pumpAndSettle();
      expect(here(), '/b');
      expect(opens(), 2);
    });
  });

  group('when the source misbehaves', () {
    testWidgets('a stream error during startup is reported once', (
      tester,
    ) async {
      captureReports();
      final source = FakeLaunchSource();
      addTearDown(source.close);
      FespalierLaunch.configure(sources: [source], route: _route);
      adapter.launch();
      source.fail(StateError('plugin'));
      await tester.pump();
      expect(reported.map((d) => '${d.exception}'), [contains('plugin')]);

      await boot(tester);
      adapter.attach(router, container);
      await tester.pumpAndSettle();
      expect(reported, hasLength(1));
      expect(here(), '/');
    });

    testWidgets('actions that cannot be read are reported at launch()', (
      tester,
    ) async {
      captureReports();
      FespalierLaunch.configure(sources: [_NoActions()], route: _route);
      expect(adapter.launch(), isNull);
      expect(reported, isNotEmpty);
      expect(
        reported.map((d) => '${d.exception}').join(),
        contains('no action channel'),
      );
    });
  });
}
