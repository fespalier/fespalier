import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The optimistic layer, built by hand the way the generated file builds it: a data provider, its
/// `optimisticLayer`, and an action whose `optimistic:` patches it. Pending writes are held on
/// `Completer`s: no timer, no `runAsync`.

final gates = <String, Completer<void>>{};
List<String> items = ['a'];
int loads = 0;

final _data = FutureProvider.autoDispose((Ref ref) async {
  loads++;
  return List<String>.of(items);
});
final _layer = optimisticLayer(_data);
final _add = actionProvider(
  (Ref ref, String input) async {
    await gates[input]!.future;
    if (input.startsWith('bad')) throw StateError(input);
    items = [...items, input];
  },
  invalidates: () => <ProviderListenable<AsyncValue<Object?>>>[_data],
  optimistic: () =>
      _layer.patch((List<String> v, String input) => [...v, input]),
);

Widget app({bool keepPrevious = true}) => ProviderScope(
  retry: (_, _) => null,
  child: MaterialApp(
    home: Material(
      child: DataView(
        watch: (ref) => ref.watch(_data),
        refresh: (ref) => ref.invalidate(_data),
        data: (d) => Text(d.join(',')),
        loading: () => const Text('Loading'),
        error: (e, st, retry) => Text('Error $e'),
        keepPrevious: keepPrevious,
        optimistic: (ref) => ref.watch(_layer),
      ),
    ),
  ),
);

/// Starts a write and drops its result: a failure is the test's business, not an unhandled one.
Future<void> write(ProviderContainer container, String input) =>
    (container.read(_add.notifier).call(input) as Future<void>).then(
      (_) {},
      onError: (Object _) {},
    );

String shown(WidgetTester tester) =>
    tester.widget<Text>(find.byType(Text)).data!;

/// Pumps [frames] frames and gives what each one showed.
Future<List<String>> frames(WidgetTester tester, int frames) async {
  final seen = <String>[];
  for (var i = 0; i < frames; i++) {
    await tester.pump();
    seen.add(shown(tester));
  }
  return seen;
}

void main() {
  setUp(() {
    items = ['a'];
    gates.clear();
    loads = 0;
  });

  testWidgets(
    "the patch shows at once and the server's value replaces it with no frame of the old one",
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      expect(find.text('a'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.text('a')),
      );
      gates['b'] = Completer();
      unawaited(write(container, 'b'));
      await tester.pump();
      expect(find.text('a,b'), findsOneWidget);
      expect(container.read(_layer).pending, 1);

      gates['b']!.complete();
      expect(await frames(tester, 4), everyElement('a,b'));
      expect(loads, 2);
      expect(container.read(_layer).isEmpty, isTrue);
    },
  );

  testWidgets('a failure rolls back', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.text('a')));
    gates['bad'] = Completer();
    unawaited(write(container, 'bad'));
    await tester.pump();
    expect(find.text('a,bad'), findsOneWidget);
    gates['bad']!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('a'), findsOneWidget);
    expect(container.read(_layer).isEmpty, isTrue);
    // The write failed: the data was not invalidated.
    expect(loads, 1);
  });

  testWidgets('two writes at once: one fails, one succeeds', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.text('a')));
    gates['b'] = Completer();
    gates['bad'] = Completer();
    unawaited(write(container, 'b'));
    unawaited(write(container, 'bad'));
    await tester.pump();
    expect(find.text('a,b,bad'), findsOneWidget);

    gates['bad']!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('a,b'), findsOneWidget);

    gates['b']!.complete();
    expect(await frames(tester, 4), everyElement('a,b'));
    expect(loads, 2);
    expect(container.read(_layer).isEmpty, isTrue);
  });

  testWidgets('keep_previous off: no loading.dart while a write settles', (
    tester,
  ) async {
    await tester.pumpWidget(app(keepPrevious: false));
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.text('a')));
    gates['b'] = Completer();
    unawaited(write(container, 'b'));
    await tester.pump();
    expect(find.text('a,b'), findsOneWidget);
    gates['b']!.complete();
    expect(await frames(tester, 4), everyElement('a,b'));
  });

  testWidgets('keep_previous off: a plain refresh still shows loading.dart', (
    tester,
  ) async {
    await tester.pumpWidget(app(keepPrevious: false));
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.text('a')));
    container.invalidate(_data);
    await tester.pump();
    expect(find.text('Loading'), findsOneWidget);
    await tester.pump();
    expect(find.text('a'), findsOneWidget);
  });

  testWidgets('the page goes away during the write', (tester) async {
    final container = ProviderContainer(retry: (_, _) => null);
    addTearDown(container.dispose);
    Widget host(Widget child) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Material(child: child)),
    );
    await tester.pumpWidget(
      host(
        DataView(
          watch: (ref) => ref.watch(_data),
          refresh: (ref) => ref.invalidate(_data),
          data: (d) => Text(d.join(',')),
          loading: () => const Text('Loading'),
          error: (e, st, retry) => Text('Error $e'),
          optimistic: (ref) => ref.watch(_layer),
        ),
      ),
    );
    await tester.pump();
    gates['b'] = Completer();
    final done = container.read(_add.notifier).call('b') as Future<void>;
    await tester.pump();
    expect(find.text('a,b'), findsOneWidget);
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pump();
    expect(container.exists(_layer), isFalse);
    gates['b']!.complete();
    await done;
    await tester.pump();
    expect(items, ['a', 'b']);
  });

  testWidgets(
    'a data() that hands back the same object after a reload drops the patch',
    (tester) async {
      final shared = <String>['x'];
      final data = FutureProvider.autoDispose((Ref ref) async => shared);
      final layer = optimisticLayer(data);
      final add = actionProvider(
        (Ref ref, String input) async => shared.add(input),
        invalidates: () => <ProviderListenable<AsyncValue<Object?>>>[data],
        optimistic: () =>
            layer.patch((List<String> v, String input) => [...v, input]),
      );
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          child: MaterialApp(
            home: Material(
              child: DataView(
                watch: (ref) => ref.watch(data),
                refresh: (ref) => ref.invalidate(data),
                data: (d) => Text(d.join(',')),
                loading: () => const Text('Loading'),
                error: (e, st, retry) => Text('Error $e'),
                optimistic: (ref) => ref.watch(layer),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final c = ProviderScope.containerOf(tester.element(find.text('x')));
      await (c.read(add.notifier).call('y') as Future<void>);
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
      expect(find.text('x,y'), findsOneWidget);
      expect(c.read(layer).isEmpty, isTrue);
    },
  );

  testWidgets('a patch that throws is reported and skipped', (tester) async {
    final data = FutureProvider.autoDispose((Ref ref) async => 1);
    final layer = optimisticLayer(data);
    final set = actionProvider(
      (Ref ref, int input) async {},
      invalidates: () => <ProviderListenable<AsyncValue<Object?>>>[data],
      optimistic: () => layer.patch((int v, int input) {
        throw StateError('patch');
      }),
    );
    await tester.pumpWidget(
      ProviderScope(
        retry: (_, _) => null,
        child: MaterialApp(
          home: Material(
            child: DataView(
              watch: (ref) => ref.watch(data),
              refresh: (ref) => ref.invalidate(data),
              data: (d) => Text('value $d'),
              loading: () => const Text('Loading'),
              error: (e, st, retry) => Text('Error $e'),
              optimistic: (ref) => ref.watch(layer),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.text('value 1')));
    final done = c.read(set.notifier).call(2) as Future<void>;
    await tester.pump();
    // Skipped, so the page shows the value as it is, and no error.dart.
    expect(find.text('value 1'), findsOneWidget);
    final exception = tester.takeException();
    expect(exception, isA<StateError>());
    await done;
  });

  testWidgets(
    'watchOptimistic patches AsyncData and leaves loading and error alone',
    (tester) async {
      final gate = Completer<int>();
      final writeGate = Completer<void>();
      var fail = false;
      final data = FutureProvider.autoDispose((Ref ref) {
        if (fail) throw StateError('no');
        return gate.future;
      });
      final layer = optimisticLayer(data);
      final set = actionProvider(
        (Ref ref, int input) => writeGate.future,
        invalidates: () => const <ProviderListenable<AsyncValue<Object?>>>[],
        optimistic: () => layer.patch((int v, int input) => v + input),
      );
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                final v = ref.watchOptimistic(data, layer);
                return Text(
                  v.isLoading && !v.hasValue
                      ? 'loading'
                      : v.hasError
                      ? 'error'
                      : 'value ${v.value}',
                );
              },
            ),
          ),
        ),
      );
      expect(find.text('loading'), findsOneWidget);
      gate.complete(10);
      await tester.pump();
      await tester.pump();
      expect(find.text('value 10'), findsOneWidget);
      final c = ProviderScope.containerOf(
        tester.element(find.text('value 10')),
      );
      unawaited((c.read(set.notifier).call(5) as Future<void>).then((_) {}));
      await tester.pump();
      expect(find.text('value 15'), findsOneWidget);
      fail = true;
      c.invalidate(data);
      await tester.pump();
      await tester.pump();
      expect(find.text('error'), findsOneWidget);
      writeGate.complete();
    },
  );

  test('begin does nothing when nothing shows the data', () async {
    final container = ProviderContainer(retry: (_, _) => null);
    addTearDown(container.dispose);
    final done = container.read(_add.notifier);
    gates['b'] = Completer();
    final write = done.call('b') as Future<void>;
    expect(container.exists(_layer), isFalse);
    gates['b']!.complete();
    await write;
    expect(container.exists(_layer), isFalse);
    expect(items, ['a', 'b']);
  });
}
