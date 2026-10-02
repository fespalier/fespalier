// DeferredLibrary and DeferredView: a page whose code loads on demand.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/deferred_page.dart' deferred as page;

/// A library whose load the test completes itself, and which counts its loads.
class Controlled {
  final completer = Completer<void>();
  var calls = 0;

  late final DeferredLibrary library = DeferredLibrary(
    () {
      calls++;
      return completer.future;
    },
    'x/page.dart',
    loadsInFakeAsync: true,
  );
}

/// A library whose loads fail until the [succeedFrom]th, which succeeds at once.
class Flaky {
  Flaky(this.succeedFrom);

  final int succeedFrom;
  var calls = 0;

  late final DeferredLibrary library = DeferredLibrary(
    () {
      calls++;
      if (calls < succeedFrom) {
        return Future<void>.error(DeferredLoadException('boom $calls'));
      }
      return Future<void>.value();
    },
    'x/page.dart',
    loadsInFakeAsync: true,
  );
}

class Counter extends StatefulWidget {
  const Counter({super.key});

  @override
  State<Counter> createState() => CounterState();
}

class CounterState extends State<Counter> {
  @override
  Widget build(BuildContext context) => const Text('page');
}

Widget view(
  DeferredLibrary library, {
  Widget Function()? page,
  List<(Object, VoidCallback)>? errors,
}) => MaterialApp(
  home: DeferredView(
    library: library,
    page: page ?? () => const Text('page'),
    loading: () => const Text('loading'),
    error: (e, st, retry) {
      errors?.add((e, retry));
      return TextButton(onPressed: retry, child: Text('error $e'));
    },
  ),
);

void main() {
  testWidgets('a loaded library builds the page in the first frame', (
    tester,
  ) async {
    final c = Controlled();
    c.completer.complete();
    await c.library.load();
    expect(c.library.isLoaded, isTrue);

    await tester.pumpWidget(view(c.library));
    expect(find.text('page'), findsOneWidget);
    expect(find.text('loading'), findsNothing);
    expect(c.calls, 1);
  });

  testWidgets('load() and preload() of a loaded library call nothing', (
    tester,
  ) async {
    final c = Controlled();
    c.completer.complete();
    await c.library.load();
    await c.library.load();
    c.library.preload();
    expect(c.calls, 1);
  });

  testWidgets('not loaded: loading, then the page one frame after it arrives', (
    tester,
  ) async {
    final c = Controlled();
    await tester.pumpWidget(view(c.library));
    expect(find.text('loading'), findsOneWidget);
    expect(find.text('page'), findsNothing);

    c.completer.complete();
    await tester.pump();
    expect(find.text('page'), findsOneWidget);
    expect(find.text('loading'), findsNothing);
    // Nothing else is scheduled: no timer, no frame.
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(c.calls, 1);
  });

  testWidgets('a failure shows error, and retry loads again', (tester) async {
    final f = Flaky(2);
    await tester.pumpWidget(view(f.library));
    await tester.pump();
    expect(find.textContaining('error'), findsOneWidget);
    expect(find.textContaining('boom 1'), findsOneWidget);
    expect(f.calls, 1);
    expect(f.library.isLoaded, isFalse);

    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(f.calls, 2);
    expect(find.text('page'), findsOneWidget);
  });

  testWidgets('the error is what loadLibrary threw', (tester) async {
    final f = Flaky(2);
    final errors = <(Object, VoidCallback)>[];
    await tester.pumpWidget(view(f.library, errors: errors));
    await tester.pump();
    expect(errors.first.$1, isA<DeferredLoadException>());
  });

  testWidgets('disposed while loading, then completed: nothing happens', (
    tester,
  ) async {
    final c = Controlled();
    await tester.pumpWidget(view(c.library));
    expect(find.text('loading'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.completer.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(c.library.isLoaded, isTrue);
  });

  testWidgets('disposed while loading, then failed: nothing happens', (
    tester,
  ) async {
    final c = Controlled();
    await tester.pumpWidget(view(c.library));
    await tester.pumpWidget(const SizedBox());
    c.completer.completeError(DeferredLoadException('late'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(c.library.isLoaded, isFalse);
  });

  testWidgets('a retry held after dispose does nothing', (tester) async {
    final f = Flaky(9);
    final errors = <(Object, VoidCallback)>[];
    await tester.pumpWidget(view(f.library, errors: errors));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    errors.first.$2();
    await tester.pump();
    expect(f.calls, 1);
  });

  testWidgets('two views and a preload share one load', (tester) async {
    final c = Controlled();
    c.library.preload();
    DeferredView of(String name) => DeferredView(
      library: c.library,
      page: () => Text(name),
      loading: () => Text('loading $name'),
      error: (e, st, retry) => const Text('error'),
    );
    await tester.pumpWidget(
      MaterialApp(home: Column(children: [of('one'), of('two')])),
    );
    expect(c.calls, 1);
    c.completer.complete();
    await tester.pump();
    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
    c.library.preload();
    expect(c.calls, 1);
  });

  testWidgets('preload of a failing load reports no unhandled error', (
    tester,
  ) async {
    final f = Flaky(9);
    f.library.preload();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(tester.takeException(), isNull);
    expect(f.calls, 1);
    expect(f.library.isLoaded, isFalse);
  });

  test('a failed load is forgotten: the next load calls again', () async {
    final f = Flaky(2);
    await expectLater(f.library.load(), throwsA(isA<DeferredLoadException>()));
    expect(f.calls, 1);
    expect(f.library.isLoaded, isFalse);
    await f.library.load();
    expect(f.calls, 2);
    expect(f.library.isLoaded, isTrue);
  });

  test('calls made while it loads share one future', () async {
    final c = Controlled();
    final a = c.library.load();
    final b = c.library.load();
    expect(identical(a, b), isTrue);
    c.completer.complete();
    await Future.wait([a, b]);
    expect(c.calls, 1);
  });

  testWidgets('the page keeps its State across the load and a parent rebuild', (
    tester,
  ) async {
    final c = Controlled();
    Widget app(String label) => MaterialApp(
      home: Column(
        children: [
          Text(label),
          DeferredView(
            library: c.library,
            page: () => const Counter(),
            loading: () => const Text('loading'),
            error: (e, st, retry) => const Text('error'),
          ),
        ],
      ),
    );
    await tester.pumpWidget(app('a'));
    c.completer.complete();
    await tester.pump();
    final state = tester.state<CounterState>(find.byType(Counter));
    await tester.pumpWidget(app('b'));
    expect(tester.state<CounterState>(find.byType(Counter)), same(state));
  });

  testWidgets('a view whose library changes loads the new one', (tester) async {
    final a = Controlled();
    final b = Controlled();
    await tester.pumpWidget(view(a.library));
    a.completer.complete();
    await tester.pump();
    expect(find.text('page'), findsOneWidget);
    await tester.pumpWidget(view(b.library));
    expect(find.text('loading'), findsOneWidget);
    b.completer.complete();
    await tester.pumpAndSettle();
    expect(find.text('page'), findsOneWidget);
  });

  test('register, anyPending and loadAll', () async {
    final a = Controlled();
    final b = Controlled();
    DeferredLibrary.register([a.library]);
    DeferredLibrary.register([a.library, b.library]);
    expect(DeferredLibrary.anyPending, isTrue);

    a.completer.complete();
    b.completer.complete();
    await DeferredLibrary.loadAll();
    expect(a.library.isLoaded && b.library.isLoaded, isTrue);
    expect(a.calls, 1, reason: 'registering twice loads once');
    expect(DeferredLibrary.anyPending, isFalse);
  });

  test('loadAll of a given list loads only that list', () async {
    final a = Controlled()..completer.complete();
    final b = Controlled();
    await DeferredLibrary.loadAll([a.library]);
    expect(a.library.isLoaded, isTrue);
    expect(b.calls, 0);
  });

  group('a real deferred import', () {
    testWidgets('pumpRouter loads it first: the page is in the first frame', (
      tester,
    ) async {
      final library = DeferredLibrary(page.loadLibrary, 'deferred_page.dart');
      DeferredLibrary.register([library]);
      expect(library.isLoaded, isFalse);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => DeferredView(
              library: library,
              page: () => page.DeferredPage(),
              loading: () => const Text('loading'),
              error: (e, st, retry) => Text('error $e'),
            ),
          ),
        ],
      );
      await pumpRouter(tester, router, settle: false);
      expect(find.text('deferred page'), findsOneWidget);
      expect(find.text('loading'), findsNothing);
      expect(library.isLoaded, isTrue);
    });

    testWidgets(
      'a router of your own that loads nothing is told what to do, not left hanging',
      (tester) async {
        final library = DeferredLibrary(page.loadLibrary, 'again.dart');
        await tester.pumpWidget(view(library));
        final error = tester.takeException();
        expect(error, isA<FlutterError>());
        expect(
          (error! as FlutterError).message,
          contains('The code of again.dart is not loaded'),
        );
      },
    );

    testWidgets('runAsync(loadAll) is what a router of your own needs', (
      tester,
    ) async {
      final library = DeferredLibrary(page.loadLibrary, 'again.dart');
      await tester.runAsync(() => DeferredLibrary.loadAll([library]));
      await tester.pumpWidget(view(library, page: () => page.DeferredPage()));
      expect(find.text('deferred page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
