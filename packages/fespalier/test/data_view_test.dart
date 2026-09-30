// DataView keeping the old value or error on screen while a provider reloads or
// retries, and QueryList as a provider key.
import 'package:fespalier/fespalier.dart';
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
            retry: (_, __) => null,
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
            retry: (_, __) => null,
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

    testWidgets('a provider with no retries shows error at once and stays', (
      tester,
    ) async {
      final flaky = Flaky(100);
      final p = FutureProvider.autoDispose(
        (ref) => flaky(),
        retry: (_, __) => null,
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
        (_, __) {},
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
}
