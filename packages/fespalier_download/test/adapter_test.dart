// The adapter seam without a generated app: a hand-made router and container. The generated
// wiring (AppAdapters) is proved end to end by examples/downloads.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_download/fespalier_adapter.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadRequest _request(String id) => DownloadRequest(
  id: id,
  url: Uri.parse('https://example.com/$id'),
  file: DownloadLocation(DownloadBase.support, 'f/$id'),
);

StoredDownload _stored(String id) => StoredDownload(_request(id));

DownloadTarget? _route(DownloadTap tap) {
  if (tap.request == null) return null;
  return switch (tap.id) {
    'a' => DownloadTarget('/a'),
    'b' => DownloadTarget('/b', extra: 7, open: DownloadOpen.push),
    'throws' => throw StateError('mapping'),
    _ => null,
  };
}

GoRouter _router() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const Text('home')),
    GoRoute(path: '/a', builder: (_, _) => const Text('a')),
    GoRoute(path: '/b', builder: (_, state) => Text('b ${state.extra}')),
  ],
);

/// The lines of [log] that belong to spans named `fespalier.download.open`: the registry's own
/// `reconciled` spans are not what these tests are about.
List<String> openSpans(List<String> log) {
  final ids = {
    for (final line in log)
      if (line.contains(' start custom fespalier.download.open'))
        line.split(' ').first,
  };
  return [
    for (final line in log)
      if (ids.contains(line.split(' ').first))
        line.substring(line.indexOf(' ') + 1),
  ];
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
    FespalierDownload.debugReset();
    reported = [];
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
  });
  tearDown(() {
    FespalierTelemetry.install(null);
    FespalierDownload.debugReset();
  });

  group('unconfigured', () {
    test('reports once, names the missing call, and does nothing', () async {
      captureReports();
      expect(adapter.launch(), isNull);
      expect(adapter.launch(), isNull);
      expect(adapter.overrides(), isEmpty);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      adapter.attach(_router(), container);
      expect(reported, hasLength(1));
      expect(
        '${reported.single.exception}',
        allOf(contains('FespalierDownload.configure'), contains('before')),
      );
    });

    test('downloadsEngine says so when read', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        () => container.read(downloadsEngine),
        throwsA(
          isA<Exception>().having((e) => '$e', 'text', contains('Override')),
        ),
      );
    });
  });

  group('configure', () {
    test(
      'binds the engine, and the notification texts reach the backend',
      () async {
        final backend = FakeDownloadBackend();
        FespalierDownload.configure(
          backend: backend,
          store: MemoryDownloadStore(),
          notifications: const DownloadNotifications(running: 'Going'),
        );
        final container = ProviderContainer(overrides: adapter.overrides());
        addTearDown(container.dispose);
        expect(container.read(downloadsEngine), isA<Downloads>());
        expect(await adapter.launch(), isNull);
        expect(backend.isOpen, isTrue);
        expect(backend.notifications?.running, 'Going');
      },
    );

    test('a second configure replaces the first', () {
      final first = FakeDownloadBackend();
      FespalierDownload.configure(backend: first, store: MemoryDownloadStore());
      final one = ProviderContainer(overrides: adapter.overrides());
      addTearDown(one.dispose);
      FespalierDownload.configure(
        backend: FakeDownloadBackend(),
        store: MemoryDownloadStore(),
      );
      final two = ProviderContainer(overrides: adapter.overrides());
      addTearDown(two.dispose);
      expect(
        identical(one.read(downloadsEngine), two.read(downloadsEngine)),
        isFalse,
      );
    });
  });

  group('cold start', () {
    FakeDownloadBackend configure({
      List<(String, DownloadTapKind)> taps = const [],
      DownloadRoute? route = _route,
      Set<String> known = const {'a', 'b', 'throws', 'x'},
    }) {
      final backend = FakeDownloadBackend(replayTaps: taps);
      FespalierDownload.configure(
        backend: backend,
        store: MemoryDownloadStore({for (final id in known) id: _stored(id)}),
        route: route,
      );
      return backend;
    }

    test('maps the tap to an InboundLaunch marked notification', () async {
      configure(taps: [('a', DownloadTapKind.body)]);
      final launch = await adapter.launch();
      expect(launch?.location, '/a');
      expect(launch?.source, NavigationSource.notification);
      expect(openSpans(rec.log), [
        'start custom fespalier.download.open',
        'end custom ok fespalier.download.routed=true',
      ]);
    });

    test('with no tap there is no launch and no span', () async {
      configure();
      expect(await adapter.launch(), isNull);
      expect(openSpans(rec.log), isEmpty);
    });

    test(
      'a tap the mapping ignores opens the app: no launch, routed=false',
      () async {
        configure(taps: [('x', DownloadTapKind.body)]);
        expect(await adapter.launch(), isNull);
        expect(
          openSpans(rec.log).last,
          'end custom ok fespalier.download.routed=false',
        );
      },
    );

    test(
      'a tap for an id the engine does not know reaches the mapping with no request',
      () async {
        DownloadTap? seen;
        configure(
          taps: [('gone', DownloadTapKind.action)],
          route: (tap) {
            seen = tap;
            return null;
          },
        );
        expect(await adapter.launch(), isNull);
        expect(seen?.request, isNull);
        expect(seen?.kind, DownloadTapKind.action);
        expect(seen?.status, isA<Absent>());
      },
    );

    test('no route configured: the app opens and goes nowhere', () async {
      configure(taps: [('a', DownloadTapKind.body)], route: null);
      expect(await adapter.launch(), isNull);
    });

    test('a throwing mapping is reported, never thrown', () async {
      captureReports();
      configure(taps: [('throws', DownloadTapKind.body)]);
      expect(await adapter.launch(), isNull);
      expect(reported, hasLength(1));
      expect('${reported.single.exception}', contains('mapping'));
    });

    test(
      'a backend that cannot open is reported, and the app starts',
      () async {
        captureReports();
        FespalierDownload.configure(
          backend: _Failing(),
          store: MemoryDownloadStore(),
        );
        expect(await adapter.launch(), isNull);
        expect(reported, hasLength(1));
      },
    );

    test('toString prints no field', () async {
      DownloadTap? seen;
      configure(
        taps: [('a', DownloadTapKind.body)],
        route: (tap) {
          seen = tap;
          return null;
        },
      );
      await adapter.launch();
      expect('$seen', 'DownloadTap');
    });
  });

  group('attach', () {
    late FakeDownloadBackend backend;
    late ProviderContainer container;
    late GoRouter router;

    Future<void> start(
      WidgetTester tester, {
      List<(String, DownloadTapKind)> coldTaps = const [],
      bool launch = true,
    }) async {
      captureReports();
      backend = FakeDownloadBackend(replayTaps: coldTaps);
      FespalierDownload.configure(
        backend: backend,
        store: MemoryDownloadStore({
          for (final id in ['a', 'b', 'x']) id: _stored(id),
        }),
        route: _route,
      );
      if (launch) await tester.runAsync(() async => adapter.launch());
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
      adapter.attach(router, container);
      await tester.runAsync(() => container.read(downloadsEngine).open());
    }

    String here() => router.routerDelegate.currentConfiguration.uri.toString();

    testWidgets('a warm tap goes, marked notification', (tester) async {
      await start(tester);
      backend.tap('a');
      await tester.pumpAndSettle();
      expect(here(), '/a');
      expect(openSpans(rec.log), [
        'start custom fespalier.download.open',
        'end custom ok fespalier.download.routed=true',
      ]);
    });

    testWidgets('open: push stacks the target and passes extra', (
      tester,
    ) async {
      await start(tester);
      backend.tap('b');
      await tester.pumpAndSettle();
      expect(find.text('b 7'), findsOneWidget);
      expect(router.canPop(), isTrue);
    });

    testWidgets(
      'a tap the mapping ignores, or maps to null, navigates nowhere',
      (tester) async {
        await start(tester);
        backend.tap('x');
        await tester.pumpAndSettle();
        expect(here(), '/');
        expect(
          openSpans(rec.log).last,
          'end custom ok fespalier.download.routed=false',
        );
      },
    );

    testWidgets('the cold-start tap seen again is dropped once', (
      tester,
    ) async {
      await start(tester, coldTaps: [('a', DownloadTapKind.body)]);
      // The launch took the first; the router has not moved (no launch was handed to it here).
      backend.tap('a');
      await tester.pumpAndSettle();
      expect(here(), '/');
      expect(
        openSpans(rec.log).where((l) => l.startsWith('start ')),
        hasLength(1),
      );
      backend.tap('a');
      await tester.pumpAndSettle();
      expect(here(), '/a');
    });

    testWidgets('the same tap twice while running is two taps', (tester) async {
      await start(tester);
      backend.tap('a');
      await tester.pumpAndSettle();
      router.go('/');
      await tester.pumpAndSettle();
      backend.tap('a');
      await tester.pumpAndSettle();
      expect(here(), '/a');
    });

    testWidgets(
      'taps heard between launch and attach are replayed, oldest first',
      (tester) async {
        captureReports();
        backend = FakeDownloadBackend(
          replayTaps: [
            ('x', DownloadTapKind.body),
            ('a', DownloadTapKind.body),
          ],
        );
        FespalierDownload.configure(
          backend: backend,
          store: MemoryDownloadStore({
            for (final id in ['a', 'x']) id: _stored(id),
          }),
          route: _route,
        );
        // `x` is the cold tap (it maps to nothing); `a` waited for the router.
        await tester.runAsync(() async => adapter.launch());
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
        adapter.attach(router, container);
        await tester.pumpAndSettle();
        expect(here(), '/a');
      },
    );

    testWidgets('attach alone opens the engine (no launch ran)', (
      tester,
    ) async {
      await start(tester, launch: false);
      expect(backend.isOpen, isTrue);
      backend.tap('a');
      await tester.pumpAndSettle();
      expect(here(), '/a');
    });

    testWidgets('a second router on the same container opens a tap once', (
      tester,
    ) async {
      await start(tester);
      final other = _router();
      addTearDown(other.dispose);
      adapter.attach(other, container);
      backend.tap('a');
      await tester.pumpAndSettle();
      expect(here(), '/a');
      expect(
        openSpans(rec.log).where((l) => l.startsWith('start ')),
        hasLength(1),
      );
    });

    testWidgets('closing the engine clears the tap slot', (tester) async {
      await start(tester);
      final engine = container.read(downloadsEngine);
      await tester.runAsync(() async {
        await engine.close();
        await engine.open();
      });
      backend.tap('a');
      await tester.pumpAndSettle();
      expect(here(), '/');
      expect(openSpans(rec.log), isEmpty);
    });
  });
}

final class _Failing extends FakeDownloadBackend {
  @override
  Future<void> open(DownloadEvents events) => throw StateError('plugin gone');
}
