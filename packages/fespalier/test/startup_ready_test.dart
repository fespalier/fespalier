// startup.dart's ready(container) and attach(router, container) (since 0.12.0): the gate makes the
// app's container, runs ready on it before the router exists, and calls attach after the adapters'.
// Every test is deterministic: a Completer the test completes, and no timer.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final greeting = Provider<String>((ref) => 'default');
final opened = Provider<String>((ref) => 'not opened');

GoRouter makeRouter() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => Consumer(
        builder: (_, ref, _) =>
            Text('home: ${ref.watch(greeting)} ${ref.watch(opened)}'),
      ),
    ),
  ],
);

Widget app(GoRouter router) => MaterialApp.router(routerConfig: router);

Widget splash(
  Object? error,
  StackTrace? stackTrace,
  VoidCallback? retry,
) => Directionality(
  textDirection: TextDirection.ltr,
  child: GestureDetector(
    onTap: retry,
    child: Text(
      'splash error=$error trace=${stackTrace != null} retry=${retry != null}',
    ),
  ),
);

base class _Seen extends ProviderObserver {
  final names = <String>[];

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) =>
      names.add(context.provider.name ?? '${context.provider.runtimeType}');
}

void main() {
  testWidgets('ready runs after startup, on the container the app uses, before '
      'the router', (tester) async {
    final log = <String>[];
    ProviderContainer? readied;
    await tester.pumpWidget(
      StartupGate(
        overrides: () {
          log.add('startup');
          return [greeting.overrideWithValue('hi')];
        },
        ready: (container) {
          log.add('ready');
          readied = container;
          // The overrides startup returned are already in this container.
          expect(container.read(greeting), 'hi');
        },
        router: () {
          log.add('router');
          return makeRouter();
        },
        app: app,
      ),
    );
    // A sync ready is done in the first frame, like a sync startup.
    expect(log, ['startup', 'ready', 'router']);
    expect(find.text('home: hi not opened'), findsOneWidget);
    final hosted = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
    );
    expect(identical(hosted, readied), isTrue);
  });

  testWidgets('an async ready shows the splash, then the app, and what it '
      'read is there', (tester) async {
    final done = Completer<void>();
    var routers = 0;
    await tester.pumpWidget(
      StartupGate(
        ready: (container) async {
          await done.future;
          expect(container.read(opened), 'not opened');
        },
        splash: splash,
        router: () {
          routers++;
          return makeRouter();
        },
        app: app,
      ),
    );
    expect(
      find.text('splash error=null trace=false retry=false'),
      findsOneWidget,
    );
    expect(routers, 0);

    done.complete();
    await tester.pumpAndSettle();
    expect(routers, 1);
    expect(find.text('home: default not opened'), findsOneWidget);
  });

  testWidgets('the container has the observers and retry policy of the scope', (
    tester,
  ) async {
    Duration? policy(int count, Object error) => null;
    final seen = _Seen();
    await tester.pumpWidget(
      StartupGate(
        observers: () => [seen],
        retry: policy,
        ready: (container) => container.read(greeting),
        router: makeRouter,
        app: app,
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
    );
    expect(container.retry, same(policy));
    expect(seen.names, isNotEmpty);
  });

  testWidgets('ready that throws is shown, and retry runs it on a fresh '
      'container without running startup again', (tester) async {
    var startups = 0;
    var attempts = 0;
    final containers = <ProviderContainer>[];
    final first = Completer<void>();
    await tester.pumpWidget(
      StartupGate(
        startup: () => startups++,
        ready: (container) {
          containers.add(container);
          return ++attempts == 1 ? first.future : null;
        },
        splash: splash,
        router: makeRouter,
        app: app,
      ),
    );
    first.completeError(StateError('no store'));
    await tester.pumpAndSettle();
    final reported = tester.takeException();
    expect(reported, isA<StateError>());
    expect(
      find.text('splash error=Bad state: no store trace=true retry=true'),
      findsOneWidget,
    );

    await tester.tap(find.textContaining('splash error'));
    await tester.pumpAndSettle();
    expect(startups, 1);
    expect(attempts, 2);
    expect(containers.length, 2);
    expect(identical(containers[0], containers[1]), isFalse);
    // The failed one is disposed.
    expect(() => containers[0].read(greeting), throwsA(isA<StateError>()));
    expect(find.text('home: default not opened'), findsOneWidget);
    final hosted = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
    );
    expect(identical(hosted, containers[1]), isTrue);
  });

  testWidgets('a ready that throws at once is reported and shown', (
    tester,
  ) async {
    await tester.pumpWidget(
      StartupGate(
        ready: (container) => throw StateError('sync boom'),
        splash: splash,
        router: makeRouter,
        app: app,
      ),
    );
    expect(tester.takeException(), isA<StateError>());
    expect(
      find.text('splash error=Bad state: sync boom trace=true retry=true'),
      findsOneWidget,
    );
  });

  testWidgets('a startup that fails is retried whole, ready included', (
    tester,
  ) async {
    var startups = 0;
    var readies = 0;
    await tester.pumpWidget(
      StartupGate(
        startup: () {
          if (++startups == 1) throw StateError('startup first');
        },
        ready: (container) => readies++,
        splash: splash,
        router: makeRouter,
        app: app,
      ),
    );
    expect(tester.takeException(), isA<StateError>());
    expect(readies, 0);
    await tester.tap(find.textContaining('splash error'));
    await tester.pumpAndSettle();
    expect(startups, 2);
    expect(readies, 1);
    expect(find.text('home: default not opened'), findsOneWidget);
  });

  testWidgets('the gate disposes its container with the tree', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      StartupGate(ready: (c) => container = c, router: makeRouter, app: app),
    );
    await tester.pumpWidget(const SizedBox());
    expect(() => container.read(greeting), throwsA(isA<StateError>()));
  });

  testWidgets('a ready that finishes after the tree is gone does nothing', (
    tester,
  ) async {
    final done = Completer<void>();
    var routers = 0;
    await tester.pumpWidget(
      StartupGate(
        ready: (_) => done.future,
        splash: splash,
        router: () {
          routers++;
          return makeRouter();
        },
        app: app,
      ),
    );
    await tester.pumpWidget(const SizedBox());
    done.complete();
    await tester.pumpAndSettle();
    expect(routers, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a ready that writes a provider and attach that listens on the '
      'same container', (tester) async {
    final counter = NotifierProvider<_Counter, int>(_Counter.new);
    ProviderContainer? attached;
    await tester.pumpWidget(
      StartupGate(
        ready: (container) => container.read(counter.notifier).increment(),
        appAttach: (router, container) {
          attached = container;
          container.listen(counter, (_, _) {});
        },
        router: () => GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => Consumer(
                builder: (_, ref, _) => Text('count: ${ref.watch(counter)}'),
              ),
            ),
          ],
        ),
        app: app,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('count: 1'), findsOneWidget);
    expect(
      identical(
        attached,
        ProviderScope.containerOf(tester.element(find.byType(Consumer))),
      ),
      isTrue,
    );
  });

  testWidgets('the app attach runs after the adapters, once, post-frame', (
    tester,
  ) async {
    final log = <String>[];
    GoRouter? made;
    await tester.pumpWidget(
      StartupGate(
        ready: (_) => log.add('ready'),
        attach: (router, container) {
          expect(identical(router, made), isTrue);
          log.add('adapters');
        },
        appAttach: (router, container) {
          expect(identical(router, made), isTrue);
          log.add('app');
        },
        router: () {
          log.add('router');
          return made = makeRouter();
        },
        app: app,
      ),
    );
    // The attach callbacks follow the frame that shows the router.
    expect(log, ['ready', 'router', 'adapters', 'app']);
    await tester.pump();
    expect(log.length, 4);
  });

  testWidgets('an adapters attach that throws does not stop the app attach, '
      'and an app attach that throws is reported', (tester) async {
    final log = <String>[];
    final reported = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) =>
        reported.add('${details.exception} ${details.context}');
    addTearDown(() => FlutterError.onError = previous);
    await tester.pumpWidget(
      StartupGate(
        attach: (router, container) => throw StateError('adapters'),
        appAttach: (router, container) {
          log.add('app');
          throw StateError('app');
        },
        router: makeRouter,
        app: app,
      ),
    );
    expect(reported.length, 2);
    expect(reported[0], contains('adapters'));
    expect(reported[1], contains('app'));
    expect(reported[1], contains('attach() in startup.dart'));
    expect(log, ['app']);
    expect(find.text('home: default not opened'), findsOneWidget);
  });

  testWidgets('attach alone, with no ready, keeps the ProviderScope path', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      StartupGate(
        appAttach: (router, container) => calls++,
        router: makeRouter,
        app: app,
      ),
    );
    await tester.pump();
    expect(calls, 1);
    expect(find.byType(ProviderScope), findsOneWidget);
  });
}

class _Counter extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state++;
}
