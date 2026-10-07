// FespalierAdapters (since 0.11.0): the adapters of `fespalier: adapters:` as one, what the
// generated `AppAdapters` forwards to. Order is the pubspec's, sync stays sync, and `attach` runs
// once per router. Deterministic: a Completer the test completes, and no timer.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/inbound.dart' show debugInboundWeb;
import 'package:fespalier/startup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final log = <String>[];

class _Recording extends FespalierAdapter {
  _Recording(
    this.name, {
    this.ready,
    this.observer,
    this.navigator,
    this.attachError,
    this.provider,
    this.launchAnswer,
    this.enter,
  });

  final String name;
  final Future<void>? ready;
  final ProviderObserver? observer;
  final NavigatorObserver? navigator;
  final Object? attachError;
  final Provider<String>? provider;
  final FutureOr<InboundLaunch?> Function()? launchAnswer;
  final FutureOr<OnEnterResult>? Function(InboundNavigation)? enter;

  @override
  FutureOr<InboundLaunch?> launch() {
    log.add('$name launch');
    return launchAnswer?.call();
  }

  @override
  FutureOr<OnEnterResult>? onEnter(InboundNavigation navigation) {
    log.add('$name onEnter');
    return enter?.call(navigation);
  }

  @override
  Future<void> zone(Future<void> Function() body) async {
    log.add('$name zone');
    await body();
    log.add('$name zone done');
  }

  @override
  Future<void>? beforeRun() {
    log.add('$name before');
    return ready;
  }

  @override
  List<Override> overrides() => [?provider?.overrideWithValue(name)];

  @override
  List<ProviderObserver> providerObservers() => [?observer];

  @override
  List<NavigatorObserver> routerObservers() => [?navigator];

  @override
  Widget wrap(Widget root) =>
      KeyedSubtree(key: ValueKey<String>('wrap $name'), child: root);

  @override
  void attach(GoRouter router, ProviderContainer container) {
    log.add('$name attach');
    if (attachError != null) throw attachError!;
  }
}

typedef Enter = FutureOr<OnEnterResult> Function({bool initial});

void muteErrors() {
  final old = FlutterError.onError;
  FlutterError.onError = (_) {};
  addTearDown(() => FlutterError.onError = old);
}

base class _Observer extends ProviderObserver {}

class _Navigator extends NavigatorObserver {}

GoRouter _router() => GoRouter(
  routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox())],
);

void main() {
  setUp(log.clear);

  group('zone and wrap', () {
    test('the first adapter is the outermost zone', () async {
      await FespalierAdapters([
        _Recording('a'),
        _Recording('b'),
        _Recording('c'),
      ]).zone(() async => log.add('body'));
      expect(log, [
        'a zone',
        'b zone',
        'c zone',
        'body',
        'c zone done',
        'b zone done',
        'a zone done',
      ]);
    });

    test('no adapters: the body runs as it is', () async {
      await FespalierAdapters(const []).zone(() async => log.add('body'));
      expect(log, ['body']);
    });

    testWidgets('the first adapter wraps outermost', (tester) async {
      final all = FespalierAdapters([_Recording('a'), _Recording('b')]);
      await tester.pumpWidget(all.wrap(const SizedBox()));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('wrap a')),
          matching: find.byKey(const ValueKey('wrap b')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('wrap b')),
          matching: find.byType(SizedBox),
        ),
        findsOneWidget,
      );
    });
  });

  group('beforeRun', () {
    test('null from every adapter: null, and no Future', () {
      final all = FespalierAdapters([_Recording('a'), _Recording('b')]);
      expect(all.beforeRun(), isNull);
      // Both ran, in order, in this very call stack.
      expect(log, ['a before', 'b before']);
    });

    test('no adapters: null', () {
      expect(FespalierAdapters(const []).beforeRun(), isNull);
    });

    test('sync stays sync: no microtask is scheduled', () {
      final all = FespalierAdapters([_Recording('a'), _Recording('b')]);
      var microtasks = 0;
      runZoned(
        () => all.beforeRun(),
        zoneSpecification: ZoneSpecification(
          scheduleMicrotask: (self, parent, zone, f) {
            microtasks++;
            parent.scheduleMicrotask(zone, f);
          },
        ),
      );
      expect(microtasks, 0);
    });

    test(
      'a Future first, then null adapters: they run after it, no timer',
      () async {
        final gate = Completer<void>();
        final all = FespalierAdapters([
          _Recording('a', ready: gate.future),
          _Recording('b'),
          _Recording('c'),
        ]);
        var timers = 0;
        final done = runZoned(
          () => all.beforeRun(),
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, d, f) {
              timers++;
              return parent.createTimer(zone, d, f);
            },
          ),
        );
        expect(done, isA<Future<void>>());
        await pumpEventQueue();
        expect(log, ['a before']);

        gate.complete();
        await done;
        expect(log, ['a before', 'b before', 'c before']);
        expect(timers, 0);
      },
    );

    test(
      'a Future in the middle keeps the order: the next waits for it',
      () async {
        final gate = Completer<void>();
        final all = FespalierAdapters([
          _Recording('a'),
          _Recording('b', ready: gate.future),
          _Recording('c'),
        ]);
        final done = all.beforeRun();
        expect(done, isA<Future<void>>());
        await pumpEventQueue();
        expect(log, ['a before', 'b before']);

        gate.complete();
        await done;
        expect(log, ['a before', 'b before', 'c before']);
      },
    );
  });

  group('overrides and observers', () {
    test("each adapter's, in the pubspec's order", () {
      final first = _Observer();
      final second = _Observer();
      final navA = _Navigator();
      final navB = _Navigator();
      final p = Provider<String>((ref) => 'x');
      final q = Provider<String>((ref) => 'x');
      final all = FespalierAdapters([
        _Recording('a', observer: first, navigator: navA, provider: p),
        _Recording('b', observer: second, navigator: navB, provider: q),
      ]);
      expect(all.providerObservers(), [first, second]);
      expect(all.routerObservers(), [navA, navB]);
      expect(all.overrides().length, 2);
    });

    test('router observers are a new list on each call', () {
      final all = FespalierAdapters([_Recording('a', navigator: _Navigator())]);
      expect(identical(all.routerObservers(), all.routerObservers()), isFalse);
    });
  });

  group('attach', () {
    test('runs each adapter once, in order, with the same arguments', () {
      final all = FespalierAdapters([_Recording('a'), _Recording('b')]);
      final router = _router();
      addTearDown(router.dispose);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      all.attach(router, container);
      expect(log, ['a attach', 'b attach']);
      all.attach(router, container);
      expect(log, [
        'a attach',
        'b attach',
      ], reason: 'attaching twice runs nothing');
    });

    test('another router is attached again', () {
      final all = FespalierAdapters([_Recording('a')]);
      final one = _router();
      final two = _router();
      addTearDown(one.dispose);
      addTearDown(two.dispose);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      all.attach(one, container);
      all.attach(two, container);
      expect(log, ['a attach', 'a attach']);
    });

    testWidgets('one that throws is reported and the others still run', (
      tester,
    ) async {
      final all = FespalierAdapters([
        _Recording('a', attachError: StateError('boom')),
        _Recording('b'),
      ]);
      final router = _router();
      addTearDown(router.dispose);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      all.attach(router, container);
      expect(log, ['a attach', 'b attach']);
      expect(tester.takeException(), isA<StateError>());
    });

    test('the default does nothing', () {
      final router = _router();
      addTearDown(router.dispose);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const _Plain().attach(router, container);
    });
  });
  group('launch', () {
    InboundLaunch at(String l) =>
        InboundLaunch(l, source: NavigationSource.notification);

    test('every adapter is asked, in order, and the first answer wins', () {
      final all = FespalierAdapters([
        _Recording('a', launchAnswer: () => null),
        _Recording('b', launchAnswer: () => at('/b')),
        _Recording('c', launchAnswer: () => at('/c')),
      ]);
      final launch = all.launch();
      expect(launch, isA<InboundLaunch>());
      expect((launch as InboundLaunch).location, '/b');
      expect(log, ['a launch', 'b launch', 'c launch']);
    });

    test('sync stays sync, and nobody has one: null', () {
      expect(
        FespalierAdapters([_Recording('a'), _Recording('b')]).launch(),
        isNull,
      );
      expect(FespalierAdapters(const []).launch(), isNull);
    });

    test(
      'a Future in the middle keeps the order and the first answer',
      () async {
        final done = Completer<InboundLaunch?>();
        final all = FespalierAdapters([
          _Recording('a', launchAnswer: () => done.future),
          _Recording('b', launchAnswer: () => at('/b')),
        ]);
        final answer = all.launch();
        expect(answer, isA<Future<InboundLaunch?>>());
        expect(log, ['a launch']);
        done.complete(at('/a'));
        expect((await answer)!.location, '/a');
        expect(log, ['a launch', 'b launch']);
      },
    );

    test('the web is never asked', () {
      debugInboundWeb = true;
      addTearDown(() => debugInboundWeb = null);
      final all = FespalierAdapters([
        _Recording('a', launchAnswer: () => at('/a')),
      ]);
      expect(all.launch(), isNull);
      expect(log, isEmpty);
    });

    test('an adapter that throws is reported and the others still answer', () {
      final errors = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = old);
      final all = FespalierAdapters([
        _Recording('a', launchAnswer: () => throw StateError('boom')),
        _Recording('b', launchAnswer: () => at('/b')),
      ]);
      expect((all.launch() as InboundLaunch).location, '/b');
      expect(errors, hasLength(1));
    });
  });

  group('onEnter', () {
    /// A router, and `onEnter` of [adapters] applied to the state it shows.
    Future<Enter> enterWith(
      WidgetTester tester,
      List<FespalierAdapter> adapters,
    ) async {
      final all = FespalierAdapters(adapters);
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox())],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      final state = router.state;
      final other = _State(Uri.parse('/other'));
      final cx = tester.element(find.byType(SizedBox));
      // go_router passes one state as both when the router has no route yet: the initial one.
      return ({bool initial = false}) =>
          all.onEnter(cx, state, initial ? state : other, router);
    }

    testWidgets('no say from anyone: a plain Allow, synchronously', (
      tester,
    ) async {
      final enter = await enterWith(tester, [_Recording('a'), _Recording('b')]);
      final result = enter();
      expect(result, isA<Allow>());
      expect((result as Allow).then, isNull);
      expect(log, ['a onEnter', 'b onEnter']);
    });

    testWidgets('the first Block wins, and the later adapters are not asked', (
      tester,
    ) async {
      final enter = await enterWith(tester, [
        _Recording('a', enter: (_) => const Allow()),
        _Recording('b', enter: (_) => const Block.stop()),
        _Recording('c', enter: (_) => const Block.then(_noop)),
      ]);
      final result = enter();
      expect(result, isA<Block>());
      expect((result as Block).isStop, isTrue);
      expect(log, ['a onEnter', 'b onEnter']);
    });

    testWidgets('the thens of the Allows are merged, in order, sync', (
      tester,
    ) async {
      final enter = await enterWith(tester, [
        _Recording('a', enter: (_) => Allow(then: () => log.add('then a'))),
        _Recording('b'),
        _Recording('c', enter: (_) => Allow(then: () => log.add('then c'))),
      ]);
      final result = enter() as Allow;
      log.clear();
      expect(result.then!(), isNull);
      expect(log, ['then a', 'then c']);
    });

    testWidgets('a then that throws is reported and the next still runs', (
      tester,
    ) async {
      final errors = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = old);
      final enter = await enterWith(tester, [
        _Recording('a', enter: (_) => Allow(then: () => throw StateError('x'))),
        _Recording('b', enter: (_) => Allow(then: () => log.add('then b'))),
      ]);
      final result = enter() as Allow;
      log.clear();
      result.then!();
      expect(log, ['then b']);
      expect(errors, hasLength(1));
    });

    testWidgets('a Future answer is awaited and the order is kept', (
      tester,
    ) async {
      final done = Completer<OnEnterResult>();
      final enter = await enterWith(tester, [
        _Recording('a', enter: (_) => done.future),
        _Recording('b', enter: (_) => const Block.stop()),
      ]);
      final result = enter();
      expect(result, isA<Future<OnEnterResult>>());
      expect(log, ['a onEnter']);
      done.complete(const Allow());
      expect(await result, isA<Block>());
      expect(log, ['a onEnter', 'b onEnter']);
    });

    testWidgets('blocking the initial navigation is refused and reported', (
      tester,
    ) async {
      final errors = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = old);
      final enter = await enterWith(tester, [
        _Recording('a', enter: (_) => const Block.stop()),
      ]);
      expect(enter(initial: true), isA<Allow>());
      expect(errors, hasLength(1));
      expect(
        errors.single.exception.toString(),
        contains('blocked the initial navigation'),
      );
      // The next one may be blocked.
      expect(enter(), isA<Block>());
    });

    testWidgets('a refused initial Block.then still runs its callback', (
      tester,
    ) async {
      muteErrors();
      final enter = await enterWith(tester, [
        _Recording('a', enter: (_) => Block.then(() => log.add('then'))),
      ]);
      final result = enter(initial: true) as Allow;
      log.clear();
      result.then!();
      expect(log, ['then']);
    });
  });
}

class _Plain extends FespalierAdapter {
  const _Plain();
}

void _noop() {}

class _State implements GoRouterState {
  _State(this.uri);

  @override
  final Uri uri;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
