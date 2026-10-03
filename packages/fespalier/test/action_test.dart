import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What `fespalier` generates for an `action.dart` is `actionProvider` / `actionFamily`
/// around the user's function; these tests build the same providers by hand, with
/// completers instead of timers, so none of them waits for real time.

/// A widget to take a [WidgetRef] from.
class Probe extends ConsumerWidget {
  const Probe({super.key, this.body});

  final Widget Function(WidgetRef ref)? body;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      body?.call(ref) ?? const SizedBox();
}

/// A data provider that counts its builds per key, like a `data.dart` the action makes stale.
class Counted {
  final builds = <String, int>{};

  late final data = FutureProvider.autoDispose.family<String, String>((
    ref,
    key,
  ) {
    builds[key] = (builds[key] ?? 0) + 1;
    return 'value $key #${builds[key]}';
  });

  /// Keeps [key] alive, as a page that watches it would, and loads it once.
  Future<void> watch(ProviderContainer c, String key) async {
    c.listen(data(key), (_, _) {});
    await c.read(data(key).future);
  }
}

/// Idle: `AsyncData(null)`.
bool isIdle(AsyncValue<Object?> state) =>
    state is AsyncData<Object?> && state.value == null;

ProviderContainer container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('the provider', () {
    test('is idle until it runs', () {
      final c = container();
      final p = actionProvider<int, int>(
        (ref, input) => input,
        invalidates: () => const [],
      );
      expect(isIdle(c.read(p)), isTrue);
    });

    test('a sync action stays sync and never shows a loading state', () {
      final c = container();
      final states = <AsyncValue<int?>>[];
      final p = actionProvider<int, int>(
        (ref, input) => input * 2,
        invalidates: () => const [],
      );
      c.listen(p, (_, next) => states.add(next));
      final result = c.read(p.notifier).call(21);
      // A value, not a Future: nothing was awaited.
      expect(result, 42);
      expect(states, [const AsyncData<int?>(42)]);
    });

    test('a sync action that throws is an error state, and throws', () {
      final c = container();
      final p = actionProvider<int, int>(
        (ref, input) => throw StateError('no'),
        invalidates: () => const [],
      );
      c.listen(p, (_, _) {});
      expect(() => c.read(p.notifier).call(1), throwsStateError);
      expect(c.read(p).error, isA<StateError>());
    });

    test(
      'an async action is loading while it runs, then has its result',
      () async {
        final c = container();
        final done = Completer<String>();
        final p = actionProvider<int, String>(
          (ref, input) => done.future,
          invalidates: () => const [],
        );
        final states = <AsyncValue<String?>>[];
        c.listen(p, (_, next) => states.add(next));

        final run = c.read(p.notifier).call(1);
        expect(run, isA<Future<String>>());
        expect(c.read(p).isLoading, isTrue);

        done.complete('refunded');
        expect(await run, 'refunded');
        expect(states.map((s) => (s.isLoading, s.value)), [
          (true, null),
          (false, 'refunded'),
        ]);
      },
    );

    test(
      'a FutureOr action returns a value when it has one, else a Future',
      () async {
        final c = container();
        final later = Completer<int>();
        final p = actionProvider<bool, int>(
          (ref, wait) => wait ? later.future : 7,
          invalidates: () => const [],
        );
        c.listen(p, (_, _) {});
        expect(c.read(p.notifier).call(false), 7);
        expect(c.read(p).value, 7);

        final pending = c.read(p.notifier).call(true);
        expect(pending, isA<Future<int>>());
        expect(c.read(p).isLoading, isTrue);
        later.complete(9);
        expect(await pending, 9);
        expect(c.read(p).value, 9);
      },
    );

    test('a failure is the error state, rethrown to the caller', () async {
      final c = container();
      final p = actionProvider<int, int>(
        (ref, input) async => throw StateError('declined'),
        invalidates: () => const [],
      );
      c.listen(p, (_, _) {});
      await expectLater(c.read(p.notifier).call(1), throwsStateError);
      final state = c.read(p);
      expect(state.hasError, isTrue);
      expect(state.error, isA<StateError>());
    });

    test('a later success replaces the error', () async {
      final c = container();
      var fail = true;
      final p = actionProvider<int, int>((ref, input) async {
        if (fail) throw StateError('declined');
        return input;
      }, invalidates: () => const []);
      c.listen(p, (_, _) {});
      await expectLater(c.read(p.notifier).call(1), throwsStateError);
      fail = false;
      expect(await c.read(p.notifier).call(5), 5);
      expect(c.read(p).value, 5);
      expect(c.read(p).hasError, isFalse);
    });

    test('reset goes back to idle', () async {
      final c = container();
      final p = actionProvider<int, int>(
        (ref, input) async => throw StateError('declined'),
        invalidates: () => const [],
      );
      c.listen(p, (_, _) {});
      await expectLater(c.read(p.notifier).call(1), throwsStateError);
      c.read(p.notifier).reset();
      expect(isIdle(c.read(p)), isTrue);
    });

    test('the action reads what it needs through its ref', () async {
      final c = container();
      final api = Provider<List<int>>((ref) => []);
      final p = actionProvider<int, int>((ref, input) async {
        ref.read(api).add(input);
        return input;
      }, invalidates: () => const []);
      await c.read(p.notifier).call(3);
      expect(c.read(api), [3]);
    });
  });

  group('keys', () {
    test('each key has a state of its own', () async {
      final c = container();
      final p = actionFamily<String, int, int>(
        (ref, key, input) async => input,
        invalidates: (key) => const [],
      );
      c.listen(p('a'), (_, _) {});
      c.listen(p('b'), (_, _) {});
      await c.read(p('a').notifier).call(1);
      expect(c.read(p('a')).value, 1);
      expect(isIdle(c.read(p('b'))), isTrue);
    });

    test('the action gets its key', () async {
      final c = container();
      final p = actionFamily<({int id}), int, String>(
        (ref, key, input) => 'order ${key.id}: $input',
        invalidates: (key) => const [],
      );
      expect(c.read(p((id: 4)).notifier).call(1), 'order 4: 1');
    });
  });

  group('after a success', () {
    test('the data it lists is invalidated, for its key only', () async {
      final c = container();
      final counted = Counted();
      await counted.watch(c, 'a');
      await counted.watch(c, 'b');
      final p = actionFamily<String, int, int>(
        (ref, key, input) async => input,
        invalidates: (key) => [counted.data(key)],
      );

      await c.read(p('a').notifier).call(1);
      expect(await c.read(counted.data('a').future), 'value a #2');
      expect(await c.read(counted.data('b').future), 'value b #1');
      expect(counted.builds, {'a': 2, 'b': 1});
    });

    test('a page and the sections above it are all invalidated', () async {
      final c = container();
      final section = Counted();
      final page = Counted();
      await section.watch(c, 'team');
      await page.watch(c, 'team/7');
      final p = actionProvider<int, void>(
        (ref, input) async {},
        invalidates: () => [section.data('team'), page.data('team/7')],
      );

      await c.read(p.notifier).call(1);
      await c.read(section.data('team').future);
      await c.read(page.data('team/7').future);
      expect(section.builds, {'team': 2});
      expect(page.builds, {'team/7': 2});
    });

    test('a failed write invalidates nothing', () async {
      final c = container();
      final counted = Counted();
      await counted.watch(c, 'a');
      final p = actionProvider<int, int>(
        (ref, input) async => throw StateError('declined'),
        invalidates: () => [counted.data('a')],
      );
      c.listen(p, (_, _) {});
      await expectLater(c.read(p.notifier).call(1), throwsStateError);
      await c.read(counted.data('a').future);
      expect(counted.builds, {'a': 1});
    });

    test('an empty list invalidates nothing', () async {
      final c = container();
      final counted = Counted();
      await counted.watch(c, 'a');
      final p = actionProvider<int, int>(
        (ref, input) async => input,
        invalidates: () => const [],
      );
      await c.read(p.notifier).call(1);
      await c.read(counted.data('a').future);
      expect(counted.builds, {'a': 1});
    });

    test(
      'something that is not a provider is a StateError that says so',
      () async {
        final c = container();
        final source = FutureProvider.autoDispose<int>((ref) => 1);
        final p = actionProvider<int, int>(
          (ref, input) async => input,
          invalidates: () => [source.select((v) => v)],
        );
        c.listen(p, (_, _) {});
        await expectLater(
          c.read(p.notifier).call(1),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('not a provider'),
            ),
          ),
        );
      },
    );
  });

  group('concurrent submissions', () {
    test('both run; the state follows the last one started', () async {
      final c = container();
      final counted = Counted();
      await counted.watch(c, 'a');
      final first = Completer<String>();
      final second = Completer<String>();
      final gates = [first, second];
      final p = actionProvider<int, String>(
        (ref, input) => gates[input].future,
        invalidates: () => [counted.data('a')],
      );
      final states = <AsyncValue<String?>>[];
      c.listen(p, (_, next) => states.add(next));

      final one = c.read(p.notifier).call(0);
      final two = c.read(p.notifier).call(1);

      // The second finishes first: it is the state, and it invalidates.
      second.complete('second');
      expect(await two, 'second');
      expect(c.read(p).value, 'second');
      expect(await c.read(counted.data('a').future), 'value a #2');

      // The first, finishing late, does not take the state back, but its write
      // succeeded, so it still invalidates.
      first.complete('first');
      expect(await one, 'first');
      expect(c.read(p).value, 'second');
      expect(await c.read(counted.data('a').future), 'value a #3');
    });

    test(
      'the first one failing late does not replace the last one\'s result',
      () async {
        final c = container();
        final first = Completer<String>();
        final p = actionProvider<int, String>(
          (ref, input) => input == 0 ? first.future : Future.value('ok'),
          invalidates: () => const [],
        );
        c.listen(p, (_, _) {});
        final one = c.read(p.notifier).call(0);
        final two = c.read(p.notifier).call(1);
        expect(await two, 'ok');
        first.completeError(StateError('late'));
        await expectLater(one, throwsStateError);
        expect(c.read(p).value, 'ok');
        expect(c.read(p).hasError, isFalse);
      },
    );

    test(
      'a reset while it runs keeps the late result out of the state',
      () async {
        final c = container();
        final done = Completer<int>();
        final counted = Counted();
        await counted.watch(c, 'a');
        final p = actionProvider<int, int>(
          (ref, input) => done.future,
          invalidates: () => [counted.data('a')],
        );
        c.listen(p, (_, _) {});
        final run = c.read(p.notifier).call(1);
        c.read(p.notifier).reset();
        expect(isIdle(c.read(p)), isTrue);
        done.complete(1);
        await run;
        expect(isIdle(c.read(p)), isTrue);
        // The write happened, so the data it made stale is still refreshed.
        await c.read(counted.data('a').future);
        expect(counted.builds['a'], 2);
      },
    );
  });

  group('after the page is gone', () {
    test(
      'a submission that finishes after nobody watches it still completes',
      () async {
        final c = container();
        final done = Completer<int>();
        final counted = Counted();
        await counted.watch(c, 'a');
        final p = actionProvider<int, int>(
          (ref, input) => done.future,
          invalidates: () => [counted.data('a')],
        );
        // Watched while it runs, then not: the page was popped.
        final sub = c.listen(p, (_, _) {});
        final run = c.read(p.notifier).call(1);
        sub.close();
        expect(
          c.exists(p),
          isTrue,
          reason: 'alive while the write is in flight',
        );

        done.complete(1);
        expect(await run, 1);
        // Dropped once it is over, and it refreshed the data.
        await c.pump();
        expect(c.exists(p), isFalse);
        await c.read(counted.data('a').future);
        expect(counted.builds['a'], 2);
      },
    );

    test('the container going away mid-run does not throw', () async {
      final c = ProviderContainer();
      final done = Completer<int>();
      final p = actionProvider<int, int>(
        (ref, input) => done.future,
        invalidates: () => const [],
      );
      c.listen(p, (_, _) {});
      final run = c.read(p.notifier).call(1);
      c.dispose();
      done.complete(1);
      expect(await run, 1);
    });

    test(
      'the container going away mid-run, then a failure, does not throw',
      () async {
        final c = ProviderContainer();
        final done = Completer<int>();
        final p = actionProvider<int, int>(
          (ref, input) => done.future,
          invalidates: () => const [],
        );
        c.listen(p, (_, _) {});
        final run = c.read(p.notifier).call(1);
        c.dispose();
        done.completeError(StateError('late'));
        await expectLater(run, throwsStateError);
      },
    );

    test('reset after the provider is gone does not throw', () {
      final c = ProviderContainer();
      final p = actionProvider<int, int>(
        (ref, input) => input,
        invalidates: () => const [],
      );
      final notifier = c.read(p.notifier);
      c.dispose();
      expect(notifier.reset, returnsNormally);
    });
  });

  group('never retried', () {
    testWidgets('a failed write runs once, however long the app waits', (
      tester,
    ) async {
      var runs = 0;
      final p = actionProvider<int, int>((ref, input) async {
        runs++;
        throw StateError('declined');
      }, invalidates: () => const []);
      // The default policy retries a failing provider with backoff; a write is not one.
      final c = ProviderContainer();
      addTearDown(c.dispose);
      late WidgetRef ref;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Probe(
              body: (r) {
                ref = r;
                r.watch(p);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await expectLater(ref.runAction(p, 1), throwsStateError);
      await tester.pump(const Duration(minutes: 5));
      expect(runs, 1);
    });
  });

  group('ActionRef', () {
    late WidgetRef ref;
    late ProviderContainer c;

    Future<void> boot(WidgetTester tester) async {
      c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Probe(
              body: (r) {
                ref = r;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
    }

    testWidgets(
      'runAction gives a Future, and fails with what the action threw',
      (tester) async {
        await boot(tester);
        final p = actionProvider<int, int>(
          (ref, input) async => input == 0 ? throw StateError('zero') : input,
          invalidates: () => const [],
        );
        expect(await ref.runAction(p, 2), 2);
        await expectLater(ref.runAction(p, 0), throwsStateError);
      },
    );

    testWidgets(
      'runAction turns a throw before the Future into a failed Future',
      (tester) async {
        await boot(tester);
        final p = actionProvider<int, int>(
          (ref, input) => throw StateError('early'),
          invalidates: () => const [],
        );
        final run = ref.runAction(p, 1);
        expect(run, isA<Future<int>>());
        await expectLater(run, throwsStateError);
      },
    );

    testWidgets(
      'runActionSync returns at once and throws what the action threw',
      (tester) async {
        await boot(tester);
        final p = actionProvider<int, int>(
          (ref, input) => input == 0 ? throw StateError('zero') : input + 1,
          invalidates: () => const [],
        );
        expect(ref.runActionSync(p, 2), 3);
        expect(() => ref.runActionSync(p, 0), throwsStateError);
      },
    );

    testWidgets('runActionOr returns what the action returned', (tester) async {
      await boot(tester);
      final later = Completer<int>();
      final p = actionProvider<bool, int>(
        (ref, wait) => wait ? later.future : 1,
        invalidates: () => const [],
      );
      expect(ref.runActionOr(p, false), 1);
      final pending = ref.runActionOr(p, true);
      expect(pending, isA<Future<int>>());
      later.complete(2);
      expect(await pending, 2);
    });

    testWidgets('the handle of a Future action: pending, error, and no throw', (
      tester,
    ) async {
      final gate = Completer<String>();
      final p = actionProvider<int, String>(
        (ref, input) => gate.future,
        invalidates: () => const [],
      );
      late ActionHandle<int, String, Future<String?>> handle;
      c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Probe(
              body: (r) {
                handle = r.watchAction(p);
                return Text(
                  handle.isPending
                      ? 'pending'
                      : handle.hasError
                      ? 'error'
                      : 'value ${handle.state.value}',
                );
              },
            ),
          ),
        ),
      );
      expect(find.text('value null'), findsOneWidget);

      final run = handle.call(1);
      await tester.pump();
      expect(find.text('pending'), findsOneWidget);
      expect(handle.isPending, isTrue);

      gate.completeError(StateError('declined'));
      // The handle does not throw: the error is in the state.
      expect(await run, isNull);
      await tester.pump();
      expect(find.text('error'), findsOneWidget);

      handle.reset();
      await tester.pump();
      expect(find.text('value null'), findsOneWidget);
    });

    testWidgets('the handle of a sync action: a value, or null on error', (
      tester,
    ) async {
      await boot(tester);
      final p = actionProvider<int, int>(
        (ref, input) => input == 0 ? throw StateError('zero') : input,
        invalidates: () => const [],
      );
      final handle = ref.watchActionSync(p);
      expect(handle.call(3), 3);
      expect(handle.call(0), isNull);
    });

    testWidgets('the handle of a FutureOr action', (tester) async {
      await boot(tester);
      final later = Completer<int>();
      final p = actionProvider<int, int>(
        (ref, input) => switch (input) {
          0 => throw StateError('zero'),
          1 => 1,
          2 => Future<int>.error(StateError('later')),
          _ => later.future,
        },
        invalidates: () => const [],
      );
      final handle = ref.watchActionOr(p);
      expect(handle.call(1), 1);
      expect(handle.call(0), isNull);
      expect(await handle.call(2), isNull);
      final pending = handle.call(3);
      expect(pending, isA<Future<int?>>());
      later.complete(3);
      expect(await pending, 3);
    });

    testWidgets('a page popped during a pending submission does not throw', (
      tester,
    ) async {
      final done = Completer<int>();
      final counted = Counted();
      final p = actionProvider<int, int>(
        (ref, input) => done.future,
        invalidates: () => [counted.data('a')],
      );
      c = ProviderContainer();
      addTearDown(c.dispose);
      await counted.watch(c, 'a');
      var show = true;
      late StateSetter rebuild;
      late Future<int?> run;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return show
                    ? Probe(
                        body: (r) {
                          final handle = r.watchAction(p);
                          return TextButton(
                            onPressed: () => run = handle.call(1),
                            child: const Text('Refund'),
                          );
                        },
                      )
                    : const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Refund'));
      await tester.pump();
      // Pop the page while the write is in flight.
      rebuild(() => show = false);
      await tester.pump();
      done.complete(1);
      expect(await run, 1);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await c.read(counted.data('a').future);
      expect(counted.builds['a'], 2);
    });

    testWidgets('the handle says which fields failed', (tester) async {
      final p = actionProvider<int, int>(
        (ref, input) => input == 0
            ? throw const FieldErrors({'n': 'Zero'})
            : input == 1
            ? throw StateError('one')
            : input,
        invalidates: () => const [],
      );
      late ActionHandle<int, int, int?> handle;
      c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Probe(
              body: (r) {
                handle = r.watchActionSync(p);
                return Text('${handle.fieldErrors?.fields}');
              },
            ),
          ),
        ),
      );
      expect(handle.fieldErrors, isNull);
      expect(handle.call(0), isNull);
      await tester.pump();
      expect(handle.fieldErrors?.fields, {'n': 'Zero'});
      expect(find.text('{n: Zero}'), findsOneWidget);
      expect(handle.call(1), isNull);
      await tester.pump();
      expect(handle.hasError, isTrue);
      expect(handle.fieldErrors, isNull);
    });
  });

  group('validate and optimistic (since 0.8.0)', () {
    test(
      'validate refuses a write before it starts, with no loading state',
      () {
        final c = container();
        var runs = 0;
        final p = actionProvider<int, int>(
          (ref, input) {
            runs++;
            return input;
          },
          invalidates: () => const [],
          validate: (input) =>
              input < 0 ? const FieldErrors({'n': 'Not negative'}) : null,
        );
        final states = <AsyncValue<int?>>[];
        c.listen(p, (_, next) => states.add(next), fireImmediately: false);
        expect(
          () => c.read(p.notifier).call(-1),
          throwsA(
            isA<FieldErrors>().having((e) => e.fields, 'fields', {
              'n': 'Not negative',
            }),
          ),
        );
        expect(runs, 0);
        expect(states, hasLength(1));
        expect(states.single.hasError, isTrue);
        expect(states.single.isLoading, isFalse);
        // A valid input goes through, and an empty FieldErrors counts as valid.
        expect(c.read(p.notifier).call(2), 2);
        expect(runs, 1);
      },
    );

    test('an empty FieldErrors from validate lets the write run', () {
      final c = container();
      final p = actionProvider<int, int>(
        (ref, input) => input,
        invalidates: () => const [],
        validate: (input) => const FieldErrors({}),
      );
      expect(c.read(p.notifier).call(1), 1);
    });
  });
}
