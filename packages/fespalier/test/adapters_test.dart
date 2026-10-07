// FespalierAdapters (since 0.11.0): the adapters of `fespalier: adapters:` as one, what the
// generated `AppAdapters` forwards to. Order is the pubspec's, sync stays sync, and `attach` runs
// once per router. Deterministic: a Completer the test completes, and no timer.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
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
  });

  final String name;
  final Future<void>? ready;
  final ProviderObserver? observer;
  final NavigatorObserver? navigator;
  final Object? attachError;
  final Provider<String>? provider;

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
}

class _Plain extends FespalierAdapter {
  const _Plain();
}
