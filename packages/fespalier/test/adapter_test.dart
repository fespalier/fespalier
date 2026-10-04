// FespalierAdapter (since 0.9.0): what a package plugs into the generated main(). `Main` below is
// what `fsp gen` writes for `adapters: [a, b]` (the Rust tests pin that text), by hand, so the
// order the calls run in is checked here: zones and wrappers outermost first, a null
// `beforeRun()` never awaited, the adapters' overrides before startup()'s own. Deterministic: a
// Completer the test completes, and no timer.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final log = <String>[];

/// Says what it was asked, and lets a test choose what `beforeRun()` returns.
class Recording extends FespalierAdapter {
  Recording(
    this.name, {
    this.ready,
    this.provider,
    this.observer,
    this.navigator,
  });

  final String name;

  /// What `beforeRun()` returns: null (nothing to wait for) or a Future.
  final Future<void>? ready;
  final Provider<String>? provider;
  final ProviderObserver? observer;
  final NavigatorObserver? navigator;

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
}

base class _Observer extends ProviderObserver {}

class _Navigator extends NavigatorObserver {}

final greeting = Provider<String>((ref) => 'default');
final other = Provider<String>((ref) => 'default');

GoRouter makeRouter() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => Consumer(
        builder: (_, ref, _) =>
            Text('home: ${ref.watch(greeting)} ${ref.watch(other)}'),
      ),
    ),
  ],
);

Widget app(GoRouter router) => MaterialApp.router(routerConfig: router);

/// The generated `AppMain` for two adapters `a` and `b`, around a startup.dart that has a
/// `zone()` (`startup`), an async `startup()` and a `providerObservers`.
class Main {
  Main(this.a, this.b, {this.startup, this.own = const []});

  final FespalierAdapter a;
  final FespalierAdapter b;
  final Future<List<Override>> Function()? startup;
  final List<Override> own;

  Future<void> run() => a.zone(() => b.zone(_main));

  Future<void> _main() async {
    if (a.beforeRun() case final ready?) await ready;
    if (b.beforeRun() case final ready?) await ready;
    log.add('runApp');
  }

  Widget root() => a.wrap(
    b.wrap(
      StartupGate(
        extraOverrides: () => [...a.overrides(), ...b.overrides()],
        overrides: startup ?? () async => own,
        observers: () => [...a.providerObservers(), ...b.providerObservers()],
        router: makeRouter,
        app: app,
      ),
    ),
  );
}

void main() {
  setUp(log.clear);

  group('the defaults add nothing', () {
    test('every member is a no-op, and a no-state adapter is const', () async {
      const a = _Plain();
      expect(identical(a, const _Plain()), isTrue);
      var ran = 0;
      await a.zone(() async => ran++);
      expect(ran, 1);
      expect(a.beforeRun(), isNull);
      expect(a.overrides(), isEmpty);
      expect(a.providerObservers(), isEmpty);
      expect(a.routerObservers(), isEmpty);
      const root = SizedBox();
      expect(identical(a.wrap(root), root), isTrue);
    });
  });

  group('zone and beforeRun', () {
    test('the first adapter is the outermost zone', () async {
      await Main(Recording('a'), Recording('b')).run();
      expect(log, [
        'a zone',
        'b zone',
        'a before',
        'b before',
        'runApp',
        'b zone done',
        'a zone done',
      ]);
    });

    test('a null beforeRun is not awaited: runApp is reached at once', () {
      // `_main` is async but has no `await` to reach: it runs to its end before it returns.
      final done = Main(Recording('a'), Recording('b'))._main();
      expect(log, ['a before', 'b before', 'runApp']);
      expect(done, isA<Future<void>>());
    });

    test('a Future from beforeRun delays runApp until it completes', () async {
      final gate = Completer<void>();
      final done = Main(
        Recording('a', ready: gate.future),
        Recording('b'),
      )._main();
      await pumpEventQueue();
      expect(log, ['a before']);

      gate.complete();
      await done;
      expect(log, ['a before', 'b before', 'runApp']);
    });
  });

  group('wrappers, overrides and observers', () {
    testWidgets('the first adapter wraps outermost, around the splash too', (
      tester,
    ) async {
      final done = Completer<List<Override>>();
      final main = Main(
        Recording('a'),
        Recording('b'),
        startup: () => done.future,
      );
      await tester.pumpWidget(
        Directionality(textDirection: TextDirection.ltr, child: main.root()),
      );
      // No splash.dart here: the gate shows nothing while startup() runs, inside both wrappers.
      expect(find.byKey(const ValueKey('wrap a')), findsOneWidget);
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
          matching: find.byType(StartupGate),
        ),
        findsOneWidget,
      );
      expect(find.byType(ProviderScope), findsNothing);

      done.complete(const []);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('wrap b')),
          matching: find.byType(ProviderScope),
        ),
        findsOneWidget,
      );
    });

    testWidgets("the adapters' overrides come before startup()'s own", (
      tester,
    ) async {
      final mine = other.overrideWithValue('startup');
      final main = Main(
        Recording('a', provider: greeting),
        Recording('b'),
        own: [mine],
      );
      await tester.pumpWidget(main.root());
      await tester.pumpAndSettle();
      expect(find.text('home: a startup'), findsOneWidget);
      final scope = tester.widget<ProviderScope>(find.byType(ProviderScope));
      expect(scope.overrides.length, 2);
      expect(identical(scope.overrides.last, mine), isTrue);
    });

    testWidgets("the adapters' provider observers are the scope's, in order", (
      tester,
    ) async {
      final first = _Observer();
      final second = _Observer();
      final main = Main(
        Recording('a', observer: first),
        Recording('b', observer: second),
      );
      await tester.pumpWidget(main.root());
      await tester.pumpAndSettle();
      final scope = tester.widget<ProviderScope>(find.byType(ProviderScope));
      expect(scope.observers, [first, second]);
    });

    test("router observers come from each adapter, a new list per call", () {
      final nav = _Navigator();
      final adapter = Recording('a', navigator: nav);
      expect(adapter.routerObservers(), [nav]);
      expect(
        identical(adapter.routerObservers(), adapter.routerObservers()),
        isFalse,
      );
    });
  });
}

class _Plain extends FespalierAdapter {
  const _Plain();
}
