// The adapter seam without a generated app: a hand-made router and container. The generated
// wiring (AppAdapters, guards) is proved end to end by examples/plugins.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_push/fespalier_adapter.dart';
import 'package:fespalier_push/fespalier_push.dart';
import 'package:fespalier_push/src/configure.dart' show pushColdStartId;
import 'package:fespalier_push/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PushTarget? _route(PushMessage m) {
  final link = m.data['link'];
  if (link is! String) return null;
  return PushTarget(
    link,
    extra: m.data['extra'],
    open: m.data['push'] == true ? PushOpen.push : PushOpen.go,
  );
}

GoRouter _router() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const Text('home')),
    GoRoute(path: '/a', builder: (_, _) => const Text('a')),
    GoRoute(path: '/b', builder: (_, state) => Text('b ${state.extra}')),
  ],
);

/// A source whose cold-start read is a Future, as a plugin's is.
final class _AsyncInitial extends FakePushSource {
  _AsyncInitial(this.message);
  final PushMessage message;
  @override
  Future<PushMessage?> initialTap() async => message;
}

final class _Failing extends FakePushSource {
  @override
  PushMessage? initialTap() => throw StateError('plugin gone');
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
    FespalierPush.debugReset();
    reported = [];
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
  });
  tearDown(() {
    FespalierTelemetry.install(null);
    FespalierPush.debugReset();
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
        allOf(contains('FespalierPush.configure'), contains('before')),
      );
    });

    test('pushSource says so when read', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        () => container.read(pushSource),
        throwsA(
          isA<Exception>().having((e) => '$e', 'text', contains('configure')),
        ),
      );
    });
  });

  group('cold start', () {
    test('maps the tap to an InboundLaunch marked notification', () {
      final source = FakePushSource(
        initial: const PushMessage(
          id: 'm1',
          data: {'link': '/orders/42', 'extra': 'x'},
        ),
      );
      FespalierPush.configure(source: source, route: _route);
      final launch = adapter.launch() as InboundLaunch?;
      expect(launch?.location, '/orders/42');
      expect(launch?.source, NavigationSource.notification);
      expect(launch?.extra, 'x');
      // It was read once.
      pushColdStartId = null;
      expect(adapter.launch(), isNull);
      expect(rec.log, [
        '#1 start custom fespalier.push.open fespalier.push.state=cold',
        '#1 end custom ok fespalier.push.routed=true',
      ]);
    });

    test('stays synchronous for a synchronous source', () {
      FespalierPush.configure(source: FakePushSource(), route: _route);
      expect(adapter.launch(), isNull);
    });

    test('awaits a Future source', () async {
      FespalierPush.configure(
        source: _AsyncInitial(const PushMessage(data: {'link': '/a'})),
        route: _route,
      );
      final launch = await adapter.launch();
      expect(launch?.location, '/a');
    });

    test(
      'a tap the mapping ignores opens the app: no launch, routed=false',
      () {
        FespalierPush.configure(
          source: FakePushSource(initial: const PushMessage(id: 'x')),
          route: _route,
        );
        expect(adapter.launch(), isNull);
        expect(rec.log.last, '#1 end custom ok fespalier.push.routed=false');
      },
    );

    test('a throwing source or mapping is reported, never thrown', () {
      captureReports();
      FespalierPush.configure(source: _Failing(), route: _route);
      expect(adapter.launch(), isNull);
      expect(reported, hasLength(1));
      FespalierPush.configure(
        source: FakePushSource(initial: const PushMessage()),
        route: (_) => throw StateError('mapping'),
      );
      expect(adapter.launch(), isNull);
      expect(reported, hasLength(2));
    });
  });

  group('attach', () {
    late FakePushSource source;
    late ProviderContainer container;
    late GoRouter router;
    late List<PushToken> tokens;
    late List<PushTokenRevoked> revoked;

    Future<void> start(
      WidgetTester tester, {
      bool onToken = false,
      bool onRevoked = false,
    }) async {
      captureReports();
      source = FakePushSource(token: _t('t1'));
      tokens = [];
      revoked = [];
      FespalierPush.configure(
        source: source,
        route: _route,
        onToken: onToken ? tokens.add : null,
        onTokenRevoked: onRevoked ? revoked.add : null,
      );
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
    }

    String here() => router.routerDelegate.currentConfiguration.uri.toString();

    testWidgets('a warm tap goes, marked notification', (tester) async {
      await start(tester);
      source.tap(const PushMessage(id: 'a', data: {'link': '/a'}));
      await tester.pumpAndSettle();
      expect(here(), '/a');
      expect(rec.log, [
        '#1 start custom fespalier.push.open fespalier.push.state=warm',
        '#1 end custom ok fespalier.push.routed=true',
      ]);
    });

    testWidgets('open: push stacks the target and passes extra', (
      tester,
    ) async {
      await start(tester);
      source.tap(
        const PushMessage(data: {'link': '/b', 'extra': 7, 'push': true}),
      );
      await tester.pumpAndSettle();
      // A pushed page does not move the address (optionURLReflectsImperativeAPIs is off).
      expect(find.text('b 7'), findsOneWidget);
      expect(router.canPop(), isTrue);
    });

    testWidgets('a tap the mapping ignores navigates nowhere', (tester) async {
      await start(tester);
      source.tap(const PushMessage(id: 'q'));
      await tester.pumpAndSettle();
      expect(here(), '/');
      expect(rec.log.last, '#1 end custom ok fespalier.push.routed=false');
    });

    testWidgets('the cold-start id seen again on taps is dropped once', (
      tester,
    ) async {
      pushColdStartId = 'cold';
      await start(tester);
      source.tap(const PushMessage(id: 'cold', data: {'link': '/a'}));
      await tester.pumpAndSettle();
      expect(here(), '/');
      expect(rec.log, isEmpty);
      source.tap(const PushMessage(id: 'cold', data: {'link': '/a'}));
      await tester.pumpAndSettle();
      expect(here(), '/a');
    });

    testWidgets('two taps of the same object are two events', (tester) async {
      await start(tester);
      const m = PushMessage(data: {'link': '/a'});
      source.tap(m);
      await tester.pumpAndSettle();
      router.go('/');
      await tester.pumpAndSettle();
      source.tap(m);
      await tester.pumpAndSettle();
      expect(here(), '/a');
    });

    testWidgets('a stream error is reported and re-opens nothing', (
      tester,
    ) async {
      await start(tester, onToken: true);
      source.tap(const PushMessage(data: {'link': '/a'}));
      await tester.pumpAndSettle();
      router.go('/');
      await tester.pumpAndSettle();
      source.tapError(StateError('plugin'));
      source.tokenError(StateError('token plugin'));
      await tester.pumpAndSettle();
      expect(here(), '/');
      expect(tokens, [_t('t1')]);
      expect(reported.map((d) => '${d.exception}'), [
        contains('plugin'),
        contains('token plugin'),
      ]);
    });

    testWidgets('a second router on the same container opens a tap once', (
      tester,
    ) async {
      await start(tester);
      final other = _router();
      addTearDown(other.dispose);
      adapter.attach(other, container);
      source.tap(const PushMessage(data: {'link': '/a'}));
      await tester.pumpAndSettle();
      expect(here(), '/a');
      // The first router took it, and `other` was never given a subscription.
      expect(rec.log.where((l) => l.contains('start custom')), hasLength(1));
    });

    testWidgets('a second notification with the same id opens too', (
      tester,
    ) async {
      await start(tester);
      source.tap(const PushMessage(id: 'x', data: {'link': '/a'}));
      await tester.pumpAndSettle();
      router.go('/');
      await tester.pumpAndSettle();
      source.tap(const PushMessage(id: 'x', data: {'link': '/a'}));
      await tester.pumpAndSettle();
      expect(here(), '/a');
    });

    testWidgets('onToken gets the current token and each refresh', (
      tester,
    ) async {
      await start(tester, onToken: true);
      await tester.pump();
      expect(tokens, [_t('t1')]);
      source.emitToken(_t('t2'));
      await tester.pump();
      source.emitToken(_t('t2'));
      await tester.pump();
      source.emitToken(_t('t3'));
      await tester.pump();
      expect(tokens, [_t('t1'), _t('t2'), _t('t3')]);
    });

    testWidgets('onTokenRevoked gets each revocation, with its properties', (
      tester,
    ) async {
      await start(tester, onToken: true, onRevoked: true);
      await tester.pump();
      expect(revoked, isEmpty);
      source.revokeToken('unifiedpush', properties: {'instance': 'a'});
      await tester.pump();
      source.revokeToken('fcm');
      await tester.pump();
      expect(revoked, [
        PushTokenRevoked(kind: 'unifiedpush', properties: {'instance': 'a'}),
        PushTokenRevoked(kind: 'fcm'),
      ]);
      // A revocation is not a token: the token callback heard only the first.
      expect(tokens, [_t('t1')]);
    });

    testWidgets(
      'tokens is listened to twice: pushToken and onToken both hear',
      (tester) async {
        captureReports();
        final counting = _Counting(token: _t('t1'));
        source = counting;
        tokens = [];
        FespalierPush.configure(
          source: counting,
          route: _route,
          onToken: tokens.add,
        );
        router = _router();
        addTearDown(router.dispose);
        container = ProviderContainer(overrides: adapter.overrides());
        addTearDown(container.dispose);
        final seen = <PushToken>[];
        final sub = container.listen<AsyncValue<PushToken>>(pushToken, (
          _,
          next,
        ) {
          if (next case AsyncData(:final value)) seen.add(value);
        }, fireImmediately: true);
        addTearDown(sub.close);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        adapter.attach(router, container);
        await tester.pump();
        counting.emitToken(_t('t2'));
        await tester.pump();
        expect(seen, [_t('t1'), _t('t2')]);
        expect(tokens, [_t('t1'), _t('t2')]);
        expect(counting.listens, 2);
      },
    );

    testWidgets('revoke, the same token again, revoke: every event is heard', (
      tester,
    ) async {
      await start(tester, onToken: true, onRevoked: true);
      await tester.pump();
      expect(tokens, [_t('t1')]);
      source.revokeToken('fcm');
      await tester.pump();
      source.emitToken(_t('t1'));
      await tester.pump();
      source.revokeToken('fcm');
      await tester.pump();
      source.revokeToken('fcm');
      await tester.pump();
      expect(tokens, [_t('t1'), _t('t1')]);
      expect(revoked, hasLength(3));
    });

    testWidgets('an equal token of the same kind is told once', (tester) async {
      await start(tester, onToken: true);
      await tester.pump();
      source.emitToken(_t('t1'));
      await tester.pump();
      source.emitToken(PushToken(kind: 'hms', value: 't1'));
      await tester.pump();
      expect(tokens, [_t('t1'), PushToken(kind: 'hms', value: 't1')]);
    });

    testWidgets('a revocation read before attach is not replayed', (
      tester,
    ) async {
      captureReports();
      source = FakePushSource();
      revoked = [];
      FespalierPush.configure(
        source: source,
        route: _route,
        onTokenRevoked: revoked.add,
      );
      router = _router();
      addTearDown(router.dispose);
      container = ProviderContainer(overrides: adapter.overrides());
      addTearDown(container.dispose);
      final sub = container.listen(pushTokenRevoked, (_, _) {});
      addTearDown(sub.close);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      source.revokeToken('fcm');
      await tester.pump();
      expect(container.read(pushTokenRevoked).value?.kind, 'fcm');
      adapter.attach(router, container);
      await tester.pump();
      expect(revoked, isEmpty);
    });

    testWidgets('pushTokenRevoked is a provider of the same events', (
      tester,
    ) async {
      await start(tester);
      final seen = <PushTokenRevoked>[];
      final sub = container.listen<AsyncValue<PushTokenRevoked>>(
        pushTokenRevoked,
        (_, next) {
          if (next case AsyncData(:final value)) seen.add(value);
        },
      );
      addTearDown(sub.close);
      source.revokeToken('hms');
      await tester.pump();
      expect(seen, [PushTokenRevoked(kind: 'hms')]);
    });

    testWidgets('a throwing onTokenRevoked is reported, not thrown', (
      tester,
    ) async {
      captureReports();
      source = FakePushSource();
      FespalierPush.configure(
        source: source,
        route: _route,
        onTokenRevoked: (_) => throw StateError('backend'),
      );
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
      await tester.pump();
      source.revokeToken('fcm');
      await tester.pump();
      expect(reported, isNotEmpty);
    });

    testWidgets('a throwing onToken is reported, not thrown', (tester) async {
      captureReports();
      source = FakePushSource(token: _t('t'));
      FespalierPush.configure(
        source: source,
        route: _route,
        onToken: (_) => throw StateError('backend'),
      );
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
      await tester.pump();
      expect(reported, isNotEmpty);
    });

    testWidgets('the permission prompt is never shown by the package', (
      tester,
    ) async {
      await start(tester, onToken: true);
      source.tap(const PushMessage(data: {'link': '/a'}));
      await tester.pumpAndSettle();
      expect(source.permissionRequests, 0);
      expect(
        await container.read(pushPermission.future),
        PushPermission.notDetermined,
      );
      expect(source.permissionRequests, 0);
      final request = FutureProvider<PushPermission>(requestPushPermission);
      final answer = await container.read(request.future);
      expect(answer, PushPermission.granted);
      expect(source.permissionRequests, 1);
    });

    testWidgets('the subscriptions go with the container', (tester) async {
      await start(tester, onToken: true);
      container.dispose();
      source.tap(const PushMessage(data: {'link': '/a'}));
      source.emitToken(_t('late'));
      await tester.pumpAndSettle();
      expect(here(), '/');
      expect(tokens, isNot(contains(_t('late'))));
    });
  });
}

PushToken _t(String value) => PushToken(kind: PushTokenKind.fcm, value: value);

/// A source that counts how many times `tokens` is listened to.
class _Counting extends FakePushSource {
  _Counting({super.token});

  int listens = 0;

  @override
  Stream<PushToken> get tokens async* {
    listens++;
    yield* super.tokens;
  }
}
