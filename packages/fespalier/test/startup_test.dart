// StartupGate: what the generated AppMain.root() returns. Every test is deterministic: a
// startup() waits on a Completer the test completes, and no timer is involved.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final greeting = Provider<String>((ref) => 'default');
final other = Provider<String>((ref) => 'default');

GoRouter makeRouter() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => Consumer(
        builder: (_, ref, _) => Text('home: ${ref.watch(greeting)}'),
      ),
    ),
  ],
);

/// A router that shows [other] as well: for what the adapters override.
GoRouter makeBothRouter() => GoRouter(
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

/// The splash the tests use: it says what it was given.
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

void main() {
  testWidgets('a sync startup is done in the first frame', (tester) async {
    var runs = 0;
    await tester.pumpWidget(
      StartupGate(
        overrides: () {
          runs++;
          return [greeting.overrideWithValue('hello')];
        },
        splash: splash,
        router: makeRouter,
        app: app,
      ),
    );
    // No pump after pumpWidget: the first frame is the app, the override is in it.
    expect(find.text('home: hello'), findsOneWidget);
    expect(find.textContaining('splash'), findsNothing);
    await tester.pumpAndSettle();
    expect(runs, 1);
  });

  testWidgets('a startup with no overrides and no splash is sync too', (
    tester,
  ) async {
    var runs = 0;
    await tester.pumpWidget(
      StartupGate(startup: () => runs++, router: makeRouter, app: app),
    );
    expect(find.text('home: default'), findsOneWidget);
    expect(runs, 1);
  });

  testWidgets('no startup builds the app at once', (tester) async {
    await tester.pumpWidget(StartupGate(router: makeRouter, app: app));
    expect(find.text('home: default'), findsOneWidget);
  });

  testWidgets('an async startup shows the splash, then the app', (
    tester,
  ) async {
    final done = Completer<List<Override>>();
    var routers = 0;
    await tester.pumpWidget(
      StartupGate(
        overrides: () => done.future,
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
    // The router waits for the startup: nothing is routed while the splash shows.
    expect(routers, 0);
    expect(find.textContaining('home'), findsNothing);

    done.complete([greeting.overrideWithValue('ready')]);
    await tester.pumpAndSettle();
    expect(find.textContaining('splash'), findsNothing);
    expect(find.text('home: ready'), findsOneWidget);
    expect(routers, 1);
  });

  testWidgets('a failing startup is reported and shown, and retried', (
    tester,
  ) async {
    var attempts = 0;
    final first = Completer<List<Override>>();
    final second = Completer<List<Override>>();
    await tester.pumpWidget(
      StartupGate(
        overrides: () => ++attempts == 1 ? first.future : second.future,
        splash: splash,
        router: makeRouter,
        app: app,
      ),
    );
    first.completeError(StateError('no disk'));
    await tester.pumpAndSettle();

    // Reported, so FlutterError.onError (and a crash reporter) sees it.
    final reported = tester.takeException();
    expect(reported, isA<StateError>());
    expect(
      find.text('splash error=Bad state: no disk trace=true retry=true'),
      findsOneWidget,
    );

    await tester.tap(find.textContaining('splash error'));
    await tester.pump();
    // Back to loading: no error, no retry, until the second run answers.
    expect(
      find.text('splash error=null trace=false retry=false'),
      findsOneWidget,
    );
    expect(attempts, 2);

    second.complete([greeting.overrideWithValue('again')]);
    await tester.pumpAndSettle();
    expect(find.text('home: again'), findsOneWidget);
  });

  testWidgets('a startup that throws at once is reported and shown', (
    tester,
  ) async {
    await tester.pumpWidget(
      StartupGate(
        startup: () => throw StateError('sync boom'),
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

  testWidgets('a failure with no splash says so, and offers to try again', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      StartupGate(
        startup: () async {
          if (++attempts == 1) throw StateError('first run');
        },
        router: makeRouter,
        app: app,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isA<StateError>());
    expect(find.text("Couldn't start the app."), findsOneWidget);
    expect(find.text('Bad state: first run'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text("Couldn't start the app."), findsNothing);
    expect(find.text('home: default'), findsOneWidget);
  });

  testWidgets('the observers are read after startup, and once', (tester) async {
    var started = false;
    var reads = 0;
    final done = Completer<void>();
    await tester.pumpWidget(
      StartupGate(
        startup: () async {
          await done.future;
          started = true;
        },
        splash: splash,
        observers: () {
          reads++;
          expect(started, isTrue, reason: 'read before startup() finished');
          return [];
        },
        router: makeRouter,
        app: app,
      ),
    );
    expect(reads, 0);
    done.complete();
    await tester.pumpAndSettle();
    expect(reads, 1);
    await tester.pumpAndSettle();
    expect(reads, 1);
  });

  testWidgets(
    "extraOverrides (the adapters', since 0.9.0) come first and are in the first frame",
    (tester) async {
      final own = greeting.overrideWithValue('own');
      final extra = other.overrideWithValue('extra');
      var reads = 0;
      await tester.pumpWidget(
        StartupGate(
          extraOverrides: () {
            reads++;
            return [extra];
          },
          overrides: () => [own],
          router: makeBothRouter,
          app: app,
        ),
      );
      // A sync startup() is done in the first frame, and so are the extra overrides.
      expect(find.text('home: own extra'), findsOneWidget);
      final scope = tester.widget<ProviderScope>(find.byType(ProviderScope));
      expect(scope.overrides.length, 2);
      expect(identical(scope.overrides.first, extra), isTrue);
      expect(identical(scope.overrides.last, own), isTrue);
      await tester.pumpAndSettle();
      expect(reads, 1);
    },
  );

  testWidgets(
    'extraOverrides are read once, after an async startup() succeeded',
    (tester) async {
      var started = false;
      var reads = 0;
      final done = Completer<List<Override>>();
      await tester.pumpWidget(
        StartupGate(
          extraOverrides: () {
            reads++;
            expect(started, isTrue, reason: 'read before startup() finished');
            return [other.overrideWithValue('extra')];
          },
          overrides: () async {
            final own = await done.future;
            started = true;
            return own;
          },
          splash: splash,
          router: makeBothRouter,
          app: app,
        ),
      );
      expect(reads, 0);
      done.complete([greeting.overrideWithValue('own')]);
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(find.text('home: own extra'), findsOneWidget);
    },
  );

  testWidgets(
    'extraOverrides with a startup that returns none, or no startup',
    (tester) async {
      await tester.pumpWidget(
        StartupGate(
          extraOverrides: () => [greeting.overrideWithValue('extra')],
          startup: () {},
          router: makeBothRouter,
          app: app,
        ),
      );
      expect(find.text('home: extra default'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        StartupGate(
          extraOverrides: () => [greeting.overrideWithValue('only')],
          router: makeBothRouter,
          app: app,
        ),
      );
      expect(find.text('home: only default'), findsOneWidget);
    },
  );

  testWidgets(
    'without extraOverrides, or with none, the scope has the startup() ones as before',
    (tester) async {
      final own = greeting.overrideWithValue('own');
      await tester.pumpWidget(
        StartupGate(overrides: () => [own], router: makeRouter, app: app),
      );
      expect(
        tester.widget<ProviderScope>(find.byType(ProviderScope)).overrides,
        [own],
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        StartupGate(
          extraOverrides: () => const [],
          overrides: () => [own],
          router: makeRouter,
          app: app,
        ),
      );
      expect(
        tester.widget<ProviderScope>(find.byType(ProviderScope)).overrides,
        [own],
      );
    },
  );

  testWidgets('an extraOverrides that throws is a startup that failed', (
    tester,
  ) async {
    await tester.pumpWidget(
      StartupGate(
        extraOverrides: () => throw StateError('adapter boom'),
        splash: splash,
        router: makeRouter,
        app: app,
      ),
    );
    expect(tester.takeException(), isA<StateError>());
    expect(
      find.text('splash error=Bad state: adapter boom trace=true retry=true'),
      findsOneWidget,
    );
  });

  testWidgets('retry reaches the ProviderScope', (tester) async {
    Duration? policy(int count, Object error) => null;
    await tester.pumpWidget(
      StartupGate(retry: policy, router: makeRouter, app: app),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
    );
    expect(container.retry, same(policy));
  });

  testWidgets('a startup that finishes after the tree is gone does nothing', (
    tester,
  ) async {
    final done = Completer<void>();
    var routers = 0;
    await tester.pumpWidget(
      StartupGate(
        startup: () => done.future,
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

  testWidgets('pumpRouter(app:) builds the widget around the router', (
    tester,
  ) async {
    await pumpRouter(
      tester,
      makeRouter(),
      app: (router) =>
          Title(title: 'The app', color: Colors.red, child: app(router)),
    );
    expect(find.text('home: default'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is Title && w.title == 'The app'),
      findsOneWidget,
    );
  });
}
