// DataView keeping the old value or error on screen while a provider reloads or
// retries, and QueryList as a provider key.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/persist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A provider that fails its first [failures] runs, then yields the number of
/// the run. [runs] counts every run.
class Flaky {
  Flaky(this.failures);

  final int failures;
  var runs = 0;

  Future<int> call() async {
    runs++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (runs <= failures) throw Exception('boom $runs');
    return runs;
  }
}

class Dep extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

Widget view(FutureProvider<int> provider, {bool keepPrevious = true}) =>
    MaterialApp(
      home: DataView<int>(
        watch: (ref) => ref.watch(provider),
        refresh: (ref) => ref.invalidate(provider),
        data: (d) => Text('data $d'),
        loading: () => const Text('loading'),
        error: (e, st, retry) =>
            TextButton(onPressed: retry, child: Text('error $e')),
        keepPrevious: keepPrevious,
      ),
    );

Duration? retryTwice(int count, Object error) =>
    count < 2 ? const Duration(milliseconds: 100) : null;

Future<void> ms(WidgetTester tester, int n) =>
    tester.pump(Duration(milliseconds: n));

void main() {
  group('a refresh (invalidate) with a value in hand', () {
    for (final keep in [true, false]) {
      testWidgets('keepPrevious: $keep', (tester) async {
        final flaky = Flaky(0);
        final p = FutureProvider.autoDispose((ref) => flaky());
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            child: view(p, keepPrevious: keep),
          ),
        );
        expect(find.text('loading'), findsOneWidget);
        await ms(tester, 20);
        expect(find.text('data 1'), findsOneWidget);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(DataView<int>)),
        );
        container.invalidate(p);
        await ms(tester, 1);
        // Riverpod's own `when` already skips loading on a refresh: with
        // keepPrevious off DataView asks for loading, so it shows.
        expect(find.text('loading'), keep ? findsNothing : findsOneWidget);
        expect(find.text('data 1'), keep ? findsOneWidget : findsNothing);
        await ms(tester, 20);
        expect(find.text('data 2'), findsOneWidget);
      });
    }
  });

  group('a reload (a dependency changed) with a value in hand', () {
    for (final keep in [true, false]) {
      testWidgets('keepPrevious: $keep', (tester) async {
        final flaky = Flaky(0);
        final dep = NotifierProvider<Dep, int>(Dep.new);
        final p = FutureProvider.autoDispose((ref) {
          ref.watch(dep);
          return flaky();
        });
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            child: view(p, keepPrevious: keep),
          ),
        );
        await ms(tester, 20);
        expect(find.text('data 1'), findsOneWidget);

        ProviderScope.containerOf(
          tester.element(find.byType(DataView<int>)),
        ).read(dep.notifier).bump();
        await ms(tester, 1);
        expect(find.text('loading'), keep ? findsNothing : findsOneWidget);
        expect(find.text('data 1'), keep ? findsOneWidget : findsNothing);
        await ms(tester, 20);
        expect(find.text('data 2'), findsOneWidget);
      });
    }
  });

  group('a provider that fails and is retried', () {
    testWidgets('shows error at once and keeps it through the retry window', (
      tester,
    ) async {
      final flaky = Flaky(2);
      final p = FutureProvider.autoDispose((ref) => flaky());
      await tester.pumpWidget(ProviderScope(retry: retryTwice, child: view(p)));
      // The first load still shows loading.
      expect(find.text('loading'), findsOneWidget);

      // Failure 1 at 10 ms: error.dart at once, then it stays while the retry
      // waits (100 ms) and runs (10 ms), failing again ...
      for (var t = 0; t < 230; t += 10) {
        await ms(tester, 10);
        if (flaky.runs < 3 || t < 220) {
          expect(find.text('loading'), findsNothing, reason: 'at ${t + 10} ms');
        }
        if (t >= 10 && flaky.runs <= 2 && t < 200) {
          expect(
            find.textContaining('error Exception: boom'),
            findsOneWidget,
            reason: 'at ${t + 10} ms',
          );
        }
      }
      // ... and the third run succeeds.
      await ms(tester, 300);
      expect(flaky.runs, 3);
      expect(find.text('data 3'), findsOneWidget);
      expect(find.textContaining('error'), findsNothing);
    });

    testWidgets('keepPrevious: false shows loading again while it retries', (
      tester,
    ) async {
      final flaky = Flaky(1);
      final p = FutureProvider.autoDispose((ref) => flaky());
      await tester.pumpWidget(
        ProviderScope(retry: retryTwice, child: view(p, keepPrevious: false)),
      );
      await ms(tester, 20);
      expect(find.text('loading'), findsOneWidget);
      await ms(tester, 300);
      expect(find.text('data 2'), findsOneWidget);
    });

    testWidgets(
      'settles into error when the policy gives up, and retry runs it again',
      (tester) async {
        final flaky = Flaky(100);
        final p = FutureProvider.autoDispose((ref) => flaky());
        await tester.pumpWidget(
          ProviderScope(retry: retryTwice, child: view(p)),
        );
        await ms(tester, 500);
        expect(flaky.runs, 3);
        expect(find.text('error Exception: boom 3'), findsOneWidget);

        // Nothing more happens by itself.
        await ms(tester, 5000);
        expect(flaky.runs, 3);

        // error.dart's retry callback invalidates the provider; the old error
        // stays up while it runs.
        await tester.tap(find.byType(TextButton));
        await ms(tester, 1);
        expect(find.text('loading'), findsNothing);
        await ms(tester, 500);
        expect(flaky.runs, 4);
        expect(find.textContaining('error Exception: boom'), findsOneWidget);
      },
    );

    testWidgets('a retry called after the view is gone does nothing', (
      tester,
    ) async {
      final flaky = Flaky(100);
      final p = FutureProvider.autoDispose(
        (ref) => flaky(),
        retry: (_, _) => null,
      );
      late VoidCallback retry;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: DataView<int>(
              watch: (ref) => ref.watch(p),
              refresh: (ref) => ref.invalidate(p),
              data: (d) => Text('data $d'),
              loading: () => const Text('loading'),
              error: (e, st, r) {
                retry = r;
                return Text('error $e');
              },
            ),
          ),
        ),
      );
      await ms(tester, 20);
      expect(find.text('error Exception: boom 1'), findsOneWidget);
      retry(); // while it is shown: loads again
      await ms(tester, 20);
      expect(flaky.runs, 2);

      await tester.pumpWidget(const SizedBox());
      retry(); // after: must not throw (a disposed ref can't be used)
      await ms(tester, 20);
      expect(flaky.runs, 2);
    });

    testWidgets('a provider with no retries shows error at once and stays', (
      tester,
    ) async {
      final flaky = Flaky(100);
      final p = FutureProvider.autoDispose(
        (ref) => flaky(),
        retry: (_, _) => null,
      );
      await tester.pumpWidget(ProviderScope(child: view(p)));
      await ms(tester, 20);
      expect(find.text('error Exception: boom 1'), findsOneWidget);
      await ms(tester, 60000);
      expect(flaky.runs, 1);
    });
  });

  group('QueryList', () {
    test('compares by value and is a plain List', () {
      final a = QueryList(['x', 'y']);
      expect(a, QueryList(['x', 'y']));
      expect(a.hashCode, QueryList(['x', 'y']).hashCode);
      expect(a, isNot(QueryList(['y', 'x'])));
      expect(a, isNot(QueryList(['x'])));
      expect(a, isNot(QueryList(<String>[])));
      expect(QueryList(<int>[]), QueryList(<int>[]));
      expect(a, isA<List<String>>());
      expect(a.join(','), 'x,y');
      expect(() => a.add('z'), throwsUnsupportedError);
    });

    test('copies its source', () {
      final source = ['a'];
      final key = QueryList(source);
      source.add('b');
      expect(key, ['a']);
    });

    test('equal lists are one provider family key', () async {
      var runs = 0;
      final family = FutureProvider.autoDispose.family((
        Ref ref,
        ({String? q, QueryList<String> tags}) k,
      ) async {
        runs++;
        return '${k.q}:${k.tags.join('+')}';
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final sub = container.listen(
        family((q: 'a', tags: QueryList(['x', 'y']))),
        (_, _) {},
      );
      expect(
        await container.read(
          family((q: 'a', tags: QueryList(['x', 'y']))).future,
        ),
        'a:x+y',
      );
      expect(runs, 1);
      await container.read(
        family((q: 'a', tags: QueryList(['y', 'x']))).future,
      );
      expect(runs, 2);
      sub.close();
    });
  });

  group('a deferred page (library:)', () {
    Widget deferredView(
      FutureProvider<int> provider,
      DeferredLibrary library, {
      List<VoidCallback>? retries,
    }) => MaterialApp(
      home: DataView<int>(
        watch: (ref) => ref.watch(provider),
        refresh: (ref) => ref.invalidate(provider),
        data: (d) => Text('page $d'),
        loading: () => const Text('loading'),
        error: (e, st, retry) {
          retries?.add(retry);
          return TextButton(onPressed: retry, child: Text('error $e'));
        },
        library: library,
      ),
    );

    DeferredLibrary controlled(Completer<void> completer, [List<int>? calls]) =>
        DeferredLibrary(
          () {
            calls?.add(1);
            return completer.future;
          },
          'x/page.dart',
          loadsInFakeAsync: true,
        );

    testWidgets(
      'loads the code with the data, and shows the page when both are there',
      (tester) async {
        final code = Completer<void>();
        final calls = <int>[];
        final flaky = Flaky(0);
        final p = FutureProvider.autoDispose((ref) => flaky());
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            child: deferredView(p, controlled(code, calls)),
          ),
        );
        // Both started in the first frame: no waterfall.
        expect(calls, hasLength(1));
        expect(flaky.runs, 1);
        expect(find.text('loading'), findsOneWidget);

        // The data first: the code is still awaited.
        await ms(tester, 20);
        expect(find.text('loading'), findsOneWidget);
        expect(find.text('page 1'), findsNothing);

        code.complete();
        await tester.pumpAndSettle();
        expect(find.text('page 1'), findsOneWidget);
        expect(calls, hasLength(1));
      },
    );

    testWidgets('the code first, then the data', (tester) async {
      final code = Completer<void>();
      final flaky = Flaky(0);
      final p = FutureProvider.autoDispose((ref) => flaky());
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          child: deferredView(p, controlled(code)),
        ),
      );
      code.complete();
      await tester.pump();
      expect(find.text('loading'), findsOneWidget);
      await ms(tester, 20);
      expect(find.text('page 1'), findsOneWidget);
    });

    testWidgets('a code error shows error with the code retry, the data stays', (
      tester,
    ) async {
      var attempts = 0;
      final flaky = Flaky(0);
      final p = FutureProvider.autoDispose((ref) => flaky());
      final library = DeferredLibrary(
        () {
          attempts++;
          // The first load is the preload at build (its failure is ignored); the view
          // the data brings tries again, fails too, and shows error.
          return attempts <= 2
              ? Future<void>.error(DeferredLoadException('chunk $attempts'))
              : Future<void>.value();
        },
        'x/page.dart',
        loadsInFakeAsync: true,
      );
      await tester.pumpWidget(
        ProviderScope(retry: (_, _) => null, child: deferredView(p, library)),
      );
      await ms(tester, 20);
      await tester.pump();
      expect(find.textContaining('chunk 2'), findsOneWidget);
      expect(flaky.runs, 1);

      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(find.text('page 1'), findsOneWidget);
      expect(attempts, 3);
      expect(flaky.runs, 1, reason: 'the data provider is not read again');
    });

    testWidgets('a data error still shows error with the data retry', (
      tester,
    ) async {
      final code = Completer<void>()..complete();
      final flaky = Flaky(1);
      final p = FutureProvider.autoDispose((ref) => flaky());
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          child: deferredView(p, controlled(code)),
        ),
      );
      await ms(tester, 20);
      expect(find.textContaining('error Exception: boom 1'), findsOneWidget);
      await tester.tap(find.byType(TextButton));
      await ms(tester, 20);
      expect(find.text('page 2'), findsOneWidget);
    });

    testWidgets('a refresh keeps the page and its State', (tester) async {
      final code = Completer<void>()..complete();
      final flaky = Flaky(0);
      final p = FutureProvider.autoDispose((ref) => flaky());
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          child: deferredView(p, controlled(code)),
        ),
      );
      await ms(tester, 20);
      expect(find.text('page 1'), findsOneWidget);
      ProviderScope.containerOf(
        tester.element(find.byType(DataView<int>)),
      ).invalidate(p);
      await ms(tester, 1);
      expect(find.text('page 1'), findsOneWidget);
      await ms(tester, 20);
      expect(find.text('page 2'), findsOneWidget);
    });
  });

  group('keepDataOnError and a value from the cache (since 0.8.0)', () {
    Widget keepView(
      FutureProvider<int> provider, {
      bool keepDataOnError = true,
      bool keepPrevious = true,
    }) => MaterialApp(
      home: DataView<int>(
        watch: (ref) => ref.watch(provider),
        refresh: (ref) => ref.invalidate(provider),
        data: (d) => Text('data $d'),
        loading: () => const Text('loading'),
        error: (e, st, retry) => Text('error $e'),
        keepPrevious: keepPrevious,
        keepDataOnError: keepDataOnError,
      ),
    );

    testWidgets('a failed reload keeps the page on its data', (tester) async {
      final flaky = Flaky(0);
      var fail = false;
      final p = FutureProvider.autoDispose((ref) async {
        final value = await flaky();
        if (fail) throw Exception('offline');
        return value;
      });
      await tester.pumpWidget(
        ProviderScope(retry: (_, _) => null, child: keepView(p)),
      );
      await ms(tester, 20);
      expect(find.text('data 1'), findsOneWidget);
      fail = true;
      ProviderScope.containerOf(
        tester.element(find.byType(DataView<int>)),
      ).invalidate(p);
      await ms(tester, 20);
      expect(find.text('data 1'), findsOneWidget);
      expect(find.textContaining('error'), findsNothing);
    });

    testWidgets('and shows the error when there is nothing to show', (
      tester,
    ) async {
      final flaky = Flaky(1);
      final p = FutureProvider.autoDispose((ref) => flaky());
      await tester.pumpWidget(
        ProviderScope(retry: (_, _) => null, child: keepView(p)),
      );
      await ms(tester, 20);
      expect(find.text('error Exception: boom 1'), findsOneWidget);
    });

    testWidgets('without it a failed reload shows the error', (tester) async {
      final flaky = Flaky(0);
      var fail = false;
      final p = FutureProvider.autoDispose((ref) async {
        final value = await flaky();
        if (fail) throw Exception('offline');
        return value;
      });
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          child: keepView(p, keepDataOnError: false),
        ),
      );
      await ms(tester, 20);
      fail = true;
      ProviderScope.containerOf(
        tester.element(find.byType(DataView<int>)),
      ).invalidate(p);
      await ms(tester, 20);
      expect(find.text('error Exception: offline'), findsOneWidget);
    });

    testWidgets('a value restored from the cache shows with keepPrevious: false, '
        'a reload without one still loads', (tester) async {
      final storage = MemoryDataStorage()
        ..write('fespalier:n', '41', const StorageOptions());
      final gate = Completer<int>();
      final cached = cachedData<int>(
        (ref) => gate.future,
        cache: DataCache<int>(encode: (v) => '$v', decode: int.parse),
        name: 'n',
      );
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [dataCacheStorage.overrideWithValue(storage)],
          child: MaterialApp(
            home: DataView<int>(
              watch: (ref) => ref.watch(cached),
              refresh: (ref) => ref.invalidate(cached),
              data: (d) => Text('data $d'),
              loading: () => const Text('loading'),
              error: (e, st, retry) => Text('error $e'),
              keepPrevious: false,
              keepDataOnError: true,
            ),
          ),
        ),
      );
      expect(find.text('data 41'), findsOneWidget);
      gate.complete(42);
      await ms(tester, 20);
      expect(find.text('data 42'), findsOneWidget);

      // No cache involved: keepPrevious false still shows loading on a refresh.
      final flaky = Flaky(0);
      final p = FutureProvider.autoDispose((ref) => flaky());
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          retry: (_, _) => null,
          child: keepView(p, keepPrevious: false),
        ),
      );
      await ms(tester, 20);
      ProviderScope.containerOf(
        tester.element(find.byType(DataView<int>)),
      ).invalidate(p);
      await ms(tester, 1);
      expect(find.text('loading'), findsOneWidget);
      await ms(tester, 20);
    });
  });
}
