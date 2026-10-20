// The adapter seam without a generated app: a hand-made router and container. The generated
// wiring (AppAdapters, guards) is proved end to end by examples/plugins.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_launch/fespalier_adapter.dart';
import 'package:fespalier_launch/fespalier_launch.dart';
import 'package:fespalier_launch/testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _widgets = widgetLinkRoute(
  schemes: const {'myapp'},
  matches: (uri) => const {'/a', '/b'}.contains(uri.path),
);

LaunchTarget? _route(LaunchAction action) => switch (action) {
  ShortcutAction(type: 'a') => LaunchTarget('/a'),
  ShortcutAction(type: 'b') => LaunchTarget(
    '/b',
    extra: 'x',
    open: LaunchOpen.push,
  ),
  ShortcutAction() => null,
  WidgetAction() => _widgets(action),
};

GoRouter _router() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const Text('home')),
    GoRoute(path: '/a', builder: (_, _) => const Text('a')),
    GoRoute(path: '/b', builder: (_, state) => Text('b ${state.extra}')),
  ],
);

/// A source whose cold-start read is a Future, as a plugin's may be.
final class _AsyncInitial extends LaunchSource {
  _AsyncInitial(this.action);
  final LaunchAction? action;
  @override
  Future<LaunchAction?> initialAction() async => action;
  @override
  Stream<LaunchAction> get actions => const Stream.empty();
}

/// A source whose cold-start read throws.
final class _SyncThrows extends LaunchSource {
  @override
  LaunchAction? initialAction() => throw StateError('plugin gone');
  @override
  Stream<LaunchAction> get actions => const Stream.empty();
}

/// A source whose cold-start read fails in its Future.
final class _FutureFails extends LaunchSource {
  @override
  Future<LaunchAction?> initialAction() =>
      Future.error(StateError('plugin future'));
  @override
  Stream<LaunchAction> get actions => const Stream.empty();
}

void main() {
  late List<FlutterErrorDetails> reported;
  late RecordingTelemetry rec;

  // flutter_test installs its own handler when a test body starts, so take it over there.
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

  group('unconfigured', () {
    test('reports once, names the missing call, and does nothing', () async {
      captureReports();
      expect(adapter.launch(), isNull);
      expect(adapter.launch(), isNull);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      adapter.attach(_router(), container);
      expect(reported, hasLength(1));
      expect(
        '${reported.single.exception}',
        allOf(contains('FespalierLaunch.configure'), contains('before')),
      );
      expect(reported.single.library, 'fespalier_launch');
    });
  });

  group('cold start', () {
    test('maps the shortcut to an InboundLaunch marked shortcut', () {
      FespalierLaunch.configure(
        sources: [FakeLaunchSource(initial: const ShortcutAction('b'))],
        route: _route,
      );
      final launch = adapter.launch() as InboundLaunch?;
      expect(launch?.location, '/b');
      expect(launch?.source, NavigationSource.shortcut);
      expect(launch?.extra, 'x');
      // Answered once by the source: a second launch() has nothing to open.
      expect(adapter.launch(), isNull);
      expect(rec.log.take(2), [
        '#1 start custom fespalier.launch.open fespalier.launch.kind=shortcut fespalier.launch.state=cold',
        '#1 end custom ok fespalier.launch.routed=true',
      ]);
    });

    test('a widget opens the app marked widget', () {
      FespalierLaunch.configure(
        sources: [
          FakeLaunchSource(initial: WidgetAction(Uri.parse('myapp:///a'))),
        ],
        route: _route,
      );
      final launch = adapter.launch() as InboundLaunch?;
      expect(launch?.location, '/a');
      expect(launch?.source, NavigationSource.widget);
      expect(
        rec.log.first,
        '#1 start custom fespalier.launch.open fespalier.launch.kind=widget fespalier.launch.state=cold',
      );
    });

    test('sync sources give a sync answer', () {
      FespalierLaunch.configure(
        sources: [FakeLaunchSource(initial: const ShortcutAction('a'))],
        route: _route,
      );
      expect(adapter.launch(), isA<InboundLaunch>());
      FespalierLaunch.configure(sources: [FakeLaunchSource()], route: _route);
      expect(adapter.launch(), isNull);
    });

    test('a Future source is awaited', () async {
      FespalierLaunch.configure(
        sources: [_AsyncInitial(const ShortcutAction('a'))],
        route: _route,
      );
      final launch = await adapter.launch();
      expect(launch?.location, '/a');
    });

    test('every source is asked once, and the first non-null answer wins', () {
      final first = FakeLaunchSource();
      final second = FakeLaunchSource(initial: const ShortcutAction('a'));
      FespalierLaunch.configure(sources: [first, second], route: _route);
      expect((adapter.launch() as InboundLaunch?)?.location, '/a');
      expect(first.initialReads, 1);
      expect(second.initialReads, 1);
    });

    test('with two answers, the first source listed wins', () {
      FespalierLaunch.configure(
        sources: [
          FakeLaunchSource(initial: const ShortcutAction('b')),
          FakeLaunchSource(initial: const ShortcutAction('a')),
        ],
        route: _route,
      );
      expect((adapter.launch() as InboundLaunch?)?.location, '/b');
    });

    test(
      'a Future and a sync answer: the Future is awaited, every source asked',
      () async {
        final sync = FakeLaunchSource();
        FespalierLaunch.configure(
          sources: [
            _AsyncInitial(null),
            sync,
            FakeLaunchSource(initial: const ShortcutAction('a')),
          ],
          route: _route,
        );
        final launch = await adapter.launch();
        expect(launch?.location, '/a');
        expect(sync.initialReads, 1);
      },
    );

    test('the same source listed twice is one source', () {
      final source = FakeLaunchSource();
      FespalierLaunch.configure(sources: [source, source], route: _route);
      expect(FespalierLaunch.configured()?.sources, [source]);
    });

    test(
      'an action the mapping ignores opens the app: no launch, routed=false',
      () {
        FespalierLaunch.configure(
          sources: [FakeLaunchSource(initial: const ShortcutAction('nope'))],
          route: _route,
        );
        expect(adapter.launch(), isNull);
        expect(rec.log.last, '#1 end custom ok fespalier.launch.routed=false');
      },
    );

    test(
      'a throwing source is reported, and another source still answers',
      () async {
        captureReports();
        FespalierLaunch.configure(
          sources: [
            _SyncThrows(),
            FakeLaunchSource(initial: const ShortcutAction('a')),
          ],
          route: _route,
        );
        expect((adapter.launch() as InboundLaunch?)?.location, '/a');
        expect(reported, hasLength(1));
        expect('${reported.single.exception}', contains('plugin gone'));
        expect(
          reported.single.context.toString(),
          contains('reading the action that opened the app'),
        );
      },
    );

    test('a failing Future is reported, never thrown', () async {
      captureReports();
      FespalierLaunch.configure(sources: [_FutureFails()], route: _route);
      expect(await adapter.launch(), isNull);
      expect(reported, hasLength(1));
      expect('${reported.single.exception}', contains('plugin future'));
    });

    test('a throwing mapping is reported, and opens the app', () {
      captureReports();
      FespalierLaunch.configure(
        sources: [FakeLaunchSource(initial: const ShortcutAction('a'))],
        route: (_) => throw StateError('mapping'),
      );
      expect(adapter.launch(), isNull);
      expect(reported, hasLength(1));
      expect(
        reported.single.context.toString(),
        contains('mapping the action to a route'),
      );
      expect(rec.log.last, '#1 end custom ok fespalier.launch.routed=false');
    });
  });

  group('attach', () {
    late FakeLaunchSource source;
    late ProviderContainer container;
    late GoRouter router;

    Future<void> start(
      WidgetTester tester, {
      List<LaunchSource>? sources,
    }) async {
      captureReports();
      source = FakeLaunchSource();
      addTearDown(source.close);
      for (final extra in sources ?? const <LaunchSource>[]) {
        if (extra is FakeLaunchSource) addTearDown(extra.close);
      }
      FespalierLaunch.configure(sources: sources ?? [source], route: _route);
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
      adapter.attach(router, container);
    }

    String here() => router.routerDelegate.currentConfiguration.uri.toString();

    testWidgets('a warm shortcut goes, marked shortcut, with state=warm', (
      tester,
    ) async {
      await start(tester);
      source.shortcut('a');
      await tester.pumpAndSettle();
      expect(here(), '/a');
      expect(rec.log, [
        '#1 start custom fespalier.launch.open fespalier.launch.kind=shortcut fespalier.launch.state=warm',
        '#1 end custom ok fespalier.launch.routed=true',
      ]);
    });

    testWidgets('a warm widget tap goes, marked widget', (tester) async {
      await start(tester);
      source.widget(Uri.parse('myapp:///b'));
      await tester.pumpAndSettle();
      expect(here(), '/b');
      expect(
        rec.log.first,
        '#1 start custom fespalier.launch.open fespalier.launch.kind=widget fespalier.launch.state=warm',
      );
    });

    testWidgets('open: push stacks the target, and passes extra', (
      tester,
    ) async {
      await start(tester);
      source.shortcut('b');
      await tester.pumpAndSettle();
      // A pushed page does not move the address (optionURLReflectsImperativeAPIs is off).
      expect(find.text('b x'), findsOneWidget);
      expect(router.canPop(), isTrue);
    });

    testWidgets('an unmapped warm action navigates nowhere', (tester) async {
      await start(tester);
      source.shortcut('nope');
      await tester.pumpAndSettle();
      expect(here(), '/');
      expect(rec.log.last, '#1 end custom ok fespalier.launch.routed=false');
    });

    testWidgets('the same action object twice gives two navigations', (
      tester,
    ) async {
      await start(tester);
      const a = ShortcutAction('a');
      source.act(a);
      await tester.pumpAndSettle();
      router.go('/');
      await tester.pumpAndSettle();
      source.act(a);
      await tester.pumpAndSettle();
      expect(here(), '/a');
    });

    testWidgets('a stream error is reported and reopens nothing', (
      tester,
    ) async {
      await start(tester);
      source.shortcut('a');
      await tester.pumpAndSettle();
      router.go('/');
      await tester.pumpAndSettle();
      source.fail(StateError('plugin'));
      await tester.pumpAndSettle();
      expect(here(), '/');
      expect(reported.map((d) => '${d.exception}'), [contains('plugin')]);
      expect(
        reported.single.context.toString(),
        contains('in the stream of launch actions'),
      );
    });

    testWidgets('a second attach on the same container opens an action once', (
      tester,
    ) async {
      await start(tester);
      final other = _router();
      addTearDown(other.dispose);
      adapter.attach(other, container);
      source.shortcut('a');
      await tester.pumpAndSettle();
      expect(here(), '/a');
      // The first router took it, and `other` was never given a subscription.
      expect(rec.log.where((l) => l.contains('start custom')), hasLength(1));
    });

    testWidgets('the subscriptions go with the container', (tester) async {
      await start(tester);
      container.dispose();
      source.shortcut('a');
      await tester.pumpAndSettle();
      expect(here(), '/');
    });

    testWidgets('one source of several: each one opens its own actions', (
      tester,
    ) async {
      final first = FakeLaunchSource();
      final second = FakeLaunchSource();
      await start(tester, sources: [first, second]);
      first.shortcut('a');
      await tester.pumpAndSettle();
      expect(here(), '/a');
      second.widget(Uri.parse('myapp:///b'));
      await tester.pumpAndSettle();
      expect(here(), '/b');
    });
  });

  test('a failing actions stream starts no timer, and is never retried', () {
    fakeAsync((async) {
      final reports = <FlutterErrorDetails>[];
      final original = FlutterError.onError;
      FlutterError.onError = reports.add;
      final source = FakeLaunchSource();
      FespalierLaunch.configure(sources: [source], route: _route);
      final container = ProviderContainer();
      final router = _router();
      adapter.launch();
      adapter.attach(router, container);
      async.flushMicrotasks();
      source.fail(StateError('plugin'));
      async.flushMicrotasks();

      expect(reports, hasLength(1));
      expect(async.pendingTimers, isEmpty);
      // Riverpod's default would ask again after 200 ms, 400 ms, 800 ms...
      async.elapse(const Duration(minutes: 2));
      expect(async.pendingTimers, isEmpty);

      FlutterError.onError = original;
      unawaited(source.close());
      container.dispose();
      router.dispose();
    });
  });
}
