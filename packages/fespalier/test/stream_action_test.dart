// A streaming action (since 0.25.0): an action.dart function that returns a `Stream<T>`. What the
// generated file builds is `streamActionProvider` / `streamActionFamily` around the user's function;
// these tests build the same providers by hand, over StreamControllers the test writes to, so none
// of them waits for real time.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A data provider that counts its builds, like a `data.dart` the action makes stale.
class Counted {
  int builds = 0;

  late final data = FutureProvider.autoDispose<int>((ref) => ++builds);

  /// Keeps the data alive, as a page that watches it would, and loads it once.
  Future<void> watch(ProviderContainer c) async {
    c.listen(data, (_, _) {});
    await c.read(data.future);
  }
}

/// The streams a test feeds: one controller per run, and whether its subscription was cancelled.
class Feeds {
  final runs = <StreamController<String>>[];
  final cancelled = <int>[];
  final inputs = <String>[];

  Stream<String> open(Ref ref, String input) {
    final index = runs.length;
    inputs.add(input);
    final controller = StreamController<String>(
      onCancel: () => cancelled.add(index),
    );
    runs.add(controller);
    return controller.stream;
  }
}

ProviderContainer container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

/// Lets the stream's events and Riverpod's disposal run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late Feeds feeds;
  late Counted counted;
  late StreamActionProvider<String, String> draft;

  setUp(() {
    feeds = Feeds();
    counted = Counted();
    draft = streamActionProvider<String, String>(
      feeds.open,
      invalidates: () => [counted.data],
      validate: (input) =>
          input.isEmpty ? const FieldErrors({'topic': 'Required'}) : null,
    );
  });

  group('the state', () {
    test('is idle until it runs', () {
      final c = container();
      final state = c.read(draft);
      expect(state, isA<StreamIdle<String>>());
      expect(state.latest, isNull);
      expect(state.count, 0);
    });

    test('runs with each item, then is done with the last one, and the '
        'call completes with it', () async {
      final c = container();
      final states = <StreamActionState<String>>[];
      c.listen(draft, (_, next) => states.add(next), fireImmediately: true);
      final run = c.read(draft.notifier).call('cats');
      expect(states.last, isA<StreamRunning<String>>());
      expect(states.last.count, 0);
      feeds.runs.single
        ..add('Cats')
        ..add('Cats sleep');
      await settle();
      expect(states.last, isA<StreamRunning<String>>());
      expect(states.last.latest, 'Cats sleep');
      expect(states.last.count, 2);
      await feeds.runs.single.close();
      expect(await run, 'Cats sleep');
      expect(c.read(draft), isA<StreamDone<String>>());
      expect(c.read(draft).latest, 'Cats sleep');
      expect(c.read(draft).count, 2);
      expect(
        [for (final s in states) s.runtimeType.toString()],
        [
          'StreamIdle<String>',
          'StreamRunning<String>',
          'StreamRunning<String>',
          'StreamRunning<String>',
          'StreamDone<String>',
        ],
      );
    });

    test('an item equal to the one before is still told', () async {
      final c = container();
      var told = 0;
      c.listen(draft, (_, _) => told++);
      final run = c.read(draft.notifier).call('x');
      feeds.runs.single
        ..add('same')
        ..add('same');
      await settle();
      // Running, then once per item.
      expect(told, 3);
      await feeds.runs.single.close();
      await run;
    });

    test('a stream that throws ends failed, keeps what arrived, and the '
        'call fails with the error', () async {
      final c = container();
      c.listen(draft, (_, _) {});
      final run = c.read(draft.notifier).call('x');
      feeds.runs.single
        ..add('half')
        ..addError(StateError('lost'));
      await expectLater(run, throwsStateError);
      final state = c.read(draft);
      expect(state, isA<StreamFailed<String>>());
      state as StreamFailed<String>;
      expect(state.error, isStateError);
      expect(state.latest, 'half');
      expect(state.count, 1);
      // The subscription ended with the error.
      expect(feeds.cancelled, [0]);
    });

    test(
      'FieldErrors from the stream end it failed, readable as such',
      () async {
        final c = container();
        c.listen(draft, (_, _) {});
        final run = c.read(draft.notifier).call('x');
        feeds.runs.single.addError(const FieldErrors({'topic': 'Too vague'}));
        await expectLater(run, throwsA(isA<FieldErrors>()));
        final state = c.read(draft) as StreamFailed<String>;
        expect((state.error as FieldErrors).fields['topic'], 'Too vague');
      },
    );
  });

  group('validate()', () {
    test('runs first: a refused input never opens the stream, and is thrown '
        'at once', () {
      final c = container();
      c.listen(draft, (_, _) {});
      expect(
        () => c.read(draft.notifier).call(''),
        throwsA(isA<FieldErrors>()),
      );
      expect(feeds.runs, isEmpty);
      final state = c.read(draft) as StreamFailed<String>;
      expect((state.error as FieldErrors).fields['topic'], 'Required');
    });

    test(
      'a function that throws before it returns its stream fails at once',
      () {
        final c = container();
        final p = streamActionProvider<String, String>(
          (ref, input) => throw StateError('no stream'),
          invalidates: () => const [],
        );
        c.listen(p, (_, _) {});
        expect(() => c.read(p.notifier).call('x'), throwsStateError);
        expect(c.read(p), isA<StreamFailed<String>>());
      },
    );
  });

  group('the last run wins', () {
    test('a new run stops the one in progress, whose call fails with '
        'StreamActionCancelled and what it had', () async {
      final c = container();
      c.listen(draft, (_, _) {});
      final first = c.read(draft.notifier).call('one');
      feeds.runs[0].add('a');
      await settle();
      final second = c.read(draft.notifier).call('two');
      expect(feeds.cancelled, [0]);
      await expectLater(
        first,
        throwsA(
          isA<StreamActionCancelled<String>>()
              .having((e) => e.latest, 'latest', 'a')
              .having((e) => e.count, 'count', 1),
        ),
      );
      // The state is the new run's, not the stopped one's.
      expect(c.read(draft), isA<StreamRunning<String>>());
      expect(c.read(draft).count, 0);
      feeds.runs[1].add('b');
      await feeds.runs[1].close();
      expect(await second, 'b');
      expect(c.read(draft).latest, 'b');
    });
  });

  group('cancel and reset', () {
    test('cancel() ends the run cancelled, with what arrived', () async {
      final c = container();
      c.listen(draft, (_, _) {});
      final run = c.read(draft.notifier).call('x');
      feeds.runs.single.add('partial');
      await settle();
      c.read(draft.notifier).cancel();
      expect(feeds.cancelled, [0]);
      await expectLater(run, throwsA(isA<StreamActionCancelled<String>>()));
      final state = c.read(draft);
      expect(state, isA<StreamCancelled<String>>());
      expect(state.latest, 'partial');
      expect(state.count, 1);
    });

    test('cancel() with no run in progress does nothing', () {
      final c = container();
      c.listen(draft, (_, _) {});
      c.read(draft.notifier).cancel();
      expect(c.read(draft), isA<StreamIdle<String>>());
    });

    test('reset() stops the run and goes back to idle', () async {
      final c = container();
      c.listen(draft, (_, _) {});
      final run = c.read(draft.notifier).call('x');
      feeds.runs.single.add('partial');
      await settle();
      c.read(draft.notifier).reset();
      expect(feeds.cancelled, [0]);
      await expectLater(run, throwsA(isA<StreamActionCancelled<String>>()));
      expect(c.read(draft), isA<StreamIdle<String>>());
    });

    test('a stopped run nobody awaits reports no error', () async {
      final unhandled = <Object>[];
      await runZonedGuarded(() async {
        final c = container();
        c.listen(draft, (_, _) {});
        // Fire and forget: a newer run, a cancel() and a reset() stop three runs.
        unawaited(c.read(draft.notifier).call('one'));
        unawaited(c.read(draft.notifier).call('two'));
        c.read(draft.notifier).cancel();
        unawaited(c.read(draft.notifier).call('three'));
        c.read(draft.notifier).reset();
        await settle();
        await settle();
      }, (error, _) => unhandled.add(error));
      expect(unhandled, isEmpty);
    });

    test('the exception does not print what the run had', () {
      const stopped = StreamActionCancelled<String>(
        latest: 'my secret draft',
        count: 3,
      );
      expect('$stopped', isNot(contains('secret')));
      expect('$stopped', contains('3 items'));
      expect(
        '${const StreamActionCancelled<String>(count: 1)}',
        contains('1 item'),
      );
    });
  });

  group('invalidation', () {
    test('a stream that ends invalidates what the action made stale', () async {
      final c = container();
      await counted.watch(c);
      c.listen(draft, (_, _) {});
      final run = c.read(draft.notifier).call('x');
      feeds.runs.single.add('a');
      await settle();
      expect(counted.builds, 1, reason: 'not while it runs');
      await feeds.runs.single.close();
      await run;
      await c.read(counted.data.future);
      expect(counted.builds, 2);
    });

    test('a run cancelled after an item invalidates; one cancelled before '
        'any does not', () async {
      final c = container();
      await counted.watch(c);
      c.listen(draft, (_, _) {});
      final empty = c.read(draft.notifier).call('x');
      c.read(draft.notifier).cancel();
      await expectLater(empty, throwsA(isA<StreamActionCancelled<String>>()));
      await c.read(counted.data.future);
      expect(counted.builds, 1);
      final some = c.read(draft.notifier).call('y');
      feeds.runs[1].add('a');
      await settle();
      c.read(draft.notifier).cancel();
      await expectLater(some, throwsA(isA<StreamActionCancelled<String>>()));
      await c.read(counted.data.future);
      expect(counted.builds, 2);
    });

    test('a run that fails after an item invalidates, as a stopped one '
        'does: a partial write is a write', () async {
      final c = container();
      await counted.watch(c);
      c.listen(draft, (_, _) {});
      final run = c.read(draft.notifier).call('x');
      feeds.runs.single
        ..add('a')
        ..addError(StateError('no'));
      await expectLater(run, throwsStateError);
      await c.read(counted.data.future);
      expect(counted.builds, 2);
    });

    test('a run that fails before its first item invalidates nothing, '
        'whether the stream or the function fails', () async {
      final c = container();
      await counted.watch(c);
      c.listen(draft, (_, _) {});
      final run = c.read(draft.notifier).call('x');
      feeds.runs.single.addError(StateError('no'));
      await expectLater(run, throwsStateError);
      // A refused input never started.
      expect(
        () => c.read(draft.notifier).call(''),
        throwsA(isA<FieldErrors>()),
      );
      // Nor does a function that throws before it returns its stream.
      final p = streamActionProvider<String, String>(
        (ref, input) => throw StateError('no stream'),
        invalidates: () => [counted.data],
      );
      c.listen(p, (_, _) {});
      expect(() => c.read(p.notifier).call('x'), throwsStateError);
      await c.read(counted.data.future);
      expect(counted.builds, 1);
    });

    test('a run stopped because nothing watches it any more invalidates '
        'nothing', () async {
      final c = container();
      await counted.watch(c);
      final sub = c.listen(draft, (_, _) {});
      final run = c.read(draft.notifier).call('x');
      feeds.runs.single.add('a');
      await settle();
      sub.close();
      await settle();
      await expectLater(run, throwsA(isA<StreamActionCancelled<String>>()));
      await c.read(counted.data.future);
      expect(counted.builds, 1, reason: 'the item was not written');
    });
  });

  group('lifetime', () {
    test('without hold, the run stops when the provider is disposed', () async {
      final c = container();
      final sub = c.listen(draft, (_, _) {});
      final run = c.read(draft.notifier).call('x');
      feeds.runs.single.add('a');
      await settle();
      sub.close();
      await settle();
      expect(feeds.cancelled, [0], reason: 'the subscription is cancelled');
      await expectLater(
        run,
        throwsA(
          isA<StreamActionCancelled<String>>().having(
            (e) => e.latest,
            'latest',
            'a',
          ),
        ),
      );
    });

    test('with hold, the provider stays alive until the stream ends', () async {
      final c = container();
      final states = <StreamActionState<String>>[];
      final run = c.read(draft.notifier).call('x', hold: true);
      final sub = c.listen(draft, (_, next) => states.add(next));
      sub.close();
      await settle();
      expect(feeds.cancelled, isEmpty, reason: 'held: still listening');
      feeds.runs.single.add('a');
      await settle();
      expect(c.read(draft).latest, 'a');
      await feeds.runs.single.close();
      expect(await run, 'a');
    });

    test('a held run is still stopped by cancel()', () async {
      final c = container();
      final run = c.read(draft.notifier).call('x', hold: true);
      c.read(draft.notifier).cancel();
      expect(feeds.cancelled, [0]);
      await expectLater(run, throwsA(isA<StreamActionCancelled<String>>()));
    });
  });

  test('a family runs with its key', () async {
    final c = container();
    final p = streamActionFamily<int, String, String>(
      (ref, key, input) => Stream.fromIterable(['$key:$input']),
      invalidates: (key) => const [],
    );
    c.listen(p(3), (_, _) {});
    expect(await c.read(p(3).notifier).call('go'), '3:go');
    expect(c.read(p(3)).latest, '3:go');
  });

  test('a whole run starts no timer, and nothing is left pending', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      c.listen(draft, (_, _) {});
      String? result;
      c.read(draft.notifier).call('x').then((v) => result = v);
      feeds.runs.single
        ..add('a')
        ..add('b');
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
      feeds.runs.single.close();
      async.flushMicrotasks();
      expect(result, 'b');
      expect(async.pendingTimers, isEmpty);
      final cancelled = c.read(draft.notifier).call('y');
      c.read(draft.notifier).cancel();
      cancelled.ignore();
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
      c.dispose();
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });

  group('telemetry', () {
    late RecordingTelemetry rec;
    const site = TelemetrySite(
      'docs/new/action.dart',
      route: '/docs/new',
      name: 'draft',
    );

    setUp(() {
      rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
    });
    tearDown(() => FespalierTelemetry.install(null));

    StreamActionProvider<String, String> traced() =>
        streamActionProvider<String, String>(
          feeds.open,
          invalidates: () => const [],
          validate: (input) =>
              input.isEmpty ? const FieldErrors({'topic': 'Required'}) : null,
          telemetry: site,
        );

    test('a run is one span with the count of its items, not one per '
        'item', () async {
      final p = traced();
      final c = container();
      c.listen(p, (_, _) {});
      final run = c.read(p.notifier).call('x');
      feeds.runs.single
        ..add('a')
        ..add('b');
      await feeds.runs.single.close();
      await run;
      expect(rec.log, [
        '#1 start action docs/new/action.dart#draft',
        '#1 end action ok async items=2',
      ]);
    });

    test('a stopped run is cancelled, a failed one an error', () async {
      final p = traced();
      final c = container();
      c.listen(p, (_, _) {});
      final first = c.read(p.notifier).call('x');
      feeds.runs[0].add('a');
      await settle();
      final second = c.read(p.notifier).call('y');
      await expectLater(first, throwsA(isA<StreamActionCancelled<String>>()));
      feeds.runs[1].addError(StateError('no'));
      await expectLater(second, throwsStateError);
      expect(() => c.read(p.notifier).call(''), throwsA(isA<FieldErrors>()));
      expect(rec.log, [
        '#1 start action docs/new/action.dart#draft',
        '#1 end action cancelled async items=1',
        '#2 start action docs/new/action.dart#draft',
        '#2 end action error async items=0 error=Bad state: no',
        '#3 start action docs/new/action.dart#draft',
        '#3 end action error invalid items=0 error=topic: Required',
      ]);
    });

    test('the stream is listened to within the action span', () async {
      final zoneKey = Object();
      FespalierTelemetry.install(_ZoneSink(zoneKey));
      Object? seen;
      final p = streamActionProvider<String, String>(
        (ref, input) async* {
          seen = Zone.current[zoneKey];
          yield input;
        },
        invalidates: () => const [],
        telemetry: site,
      );
      final c = container();
      c.listen(p, (_, _) {});
      expect(await c.read(p.notifier).call('x'), 'x');
      expect(seen, 'span');
    });

    test('only the stream itself runs in the span: what the notifier does '
        'with its events, and the listeners it wakes, run in the caller\'s '
        'zone', () async {
      final key = Object();
      final sink = _ParentSink(key);
      FespalierTelemetry.install(sink);
      Object? inBody;
      final first = streamActionProvider<String, String>(
        (ref, input) async* {
          inBody = Zone.current[key];
          yield input;
        },
        invalidates: () => const [],
        telemetry: site,
      );
      final second = streamActionProvider<String, String>(
        (ref, input) => Stream.value(input),
        invalidates: () => const [],
        telemetry: const TelemetrySite(
          'docs/new/action.dart',
          route: '/docs/new',
          name: 'again',
        ),
      );
      final c = container();
      Object? inListener;
      Object? startedUnder = 'not started';
      Future<String?>? followUp;
      c.listen(first, (_, next) {
        if (next is! StreamDone<String>) return;
        inListener = Zone.current[key];
        // What a page does when the first action is done: another action.
        followUp = c.read(second.notifier).call('next');
      });
      c.listen(second, (_, _) {});
      await c.read(first.notifier).call('x');
      await followUp;
      startedUnder = sink.parents.last;
      expect(inBody, isNotNull, reason: 'the body is the span\'s child');
      expect(inListener, isNull, reason: 'a listener is not in the span');
      expect(
        startedUnder,
        isNull,
        reason: 'the follow-up is not a child of the ended stream span',
      );
    });
  });

  group('a call that cannot run starts nothing, or ends what it started', () {
    late RecordingTelemetry rec;
    const site = TelemetrySite(
      'docs/new/action.dart',
      route: '/docs/new',
      name: 'draft',
    );

    setUp(() {
      rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
    });
    tearDown(() => FespalierTelemetry.install(null));

    StreamActionProvider<String, String> traced() =>
        streamActionProvider<String, String>(
          feeds.open,
          invalidates: () => const [],
          telemetry: site,
        );

    test('after the provider was disposed: a StateError, and no span, '
        'stream or run', () async {
      final p = traced();
      final c = container();
      final sub = c.listen(p, (_, _) {});
      final notifier = c.read(p.notifier);
      sub.close();
      await settle();
      expect(() => notifier.call('x'), throwsStateError);
      expect(() => notifier.call('x', hold: true), throwsStateError);
      expect(feeds.runs, isEmpty);
      expect(rec.log, isEmpty);
    });

    testWidgets('while the widget tree builds: the refusal is thrown, the '
        'span ends once with an error, the link is released and the next '
        'call runs', (tester) async {
      final p = traced();
      Object? refused;
      late WidgetRef widgetRef;
      await tester.pumpWidget(
        ProviderScope(
          child: Consumer(
            builder: (context, ref, _) {
              widgetRef = ref;
              if (refused == null) {
                try {
                  ref.read(p.notifier).call('x', hold: true);
                } catch (e) {
                  refused = e;
                }
              }
              return const SizedBox();
            },
          ),
        ),
      );
      expect(refused, isNotNull, reason: 'Riverpod refuses the state write');
      expect(feeds.runs, isEmpty, reason: 'the stream was never opened');
      expect(rec.log, hasLength(2));
      expect(rec.log.first, '#1 start action docs/new/action.dart#draft');
      expect(rec.log.last, startsWith('#1 end action error'));
      // Nothing holds the provider any more, and nothing is left running.
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(Consumer)),
      );
      expect(container.exists(p), isFalse, reason: 'the link was released');
      // The next call, from an event handler, runs.
      final run = widgetRef.read(p.notifier).call('y', hold: true);
      feeds.runs.single.add('a');
      await feeds.runs.single.close();
      expect(await run, 'a');
      expect(rec.log.last, '#2 end action ok async items=1');
    });
  });

  group('the handle', () {
    testWidgets('runs, shows the items, and stops when the page goes away', (
      tester,
    ) async {
      StreamActionHandle<String, String>? handle;
      final show = ValueNotifier(true);
      addTearDown(show.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ValueListenableBuilder<bool>(
              valueListenable: show,
              builder: (context, on, _) => on
                  ? Consumer(
                      builder: (context, ref, _) {
                        final h = handle = ref.watchActionStream(draft);
                        return Text(
                          '${h.value ?? '-'} ${h.isPending ? 'running' : 'idle'}',
                        );
                      },
                    )
                  : const Text('gone'),
            ),
          ),
        ),
      );
      expect(find.text('- idle'), findsOneWidget);
      final run = handle!.call('x');
      await tester.pump();
      expect(find.text('- running'), findsOneWidget);
      feeds.runs.single.add('Hello');
      await tester.pump();
      await tester.pump();
      expect(find.text('Hello running'), findsOneWidget);
      show.value = false;
      await tester.pump();
      await tester.pump();
      expect(feeds.cancelled, [0], reason: 'the page went away');
      // The handle never throws, and never takes a partial result for a whole one.
      expect(await run, isNull);
    });

    testWidgets('a failed run is in the state, not thrown, with its field '
        'errors', (tester) async {
      StreamActionHandle<String, String>? handle;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                handle = ref.watchActionStream(draft);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(await handle!.call(''), isNull);
      await tester.pump();
      expect(handle!.hasError, isTrue);
      expect(handle!.fieldErrors?.fields['topic'], 'Required');
      handle!.reset();
      await tester.pump();
      expect(handle!.state, isA<StreamIdle<String>>());
    });
  });
}

/// A sink whose `within` runs the body in a zone that names the span, as an OpenTelemetry sink
/// makes the span current.
final class _ZoneSink extends FespalierTelemetry {
  _ZoneSink(this.key);

  final Object key;

  @override
  Object? start(TelemetryStart start) => 'span';

  @override
  void within(Object? token, Object? Function() body) =>
      runZoned(body, zoneValues: {key: token});
}

/// A sink that makes the zone of `within` name the span, and notes which zone each span starts in
/// (null: none), as an OpenTelemetry sink parents a span to the current context.
final class _ParentSink extends FespalierTelemetry {
  _ParentSink(this.key);

  final Object key;
  final List<Object?> parents = [];
  int _last = 0;

  @override
  Object? start(TelemetryStart start) {
    parents.add(Zone.current[key]);
    return 'span#${++_last}';
  }

  @override
  void within(Object? token, Object? Function() body) =>
      runZoned(body, zoneValues: {key: token});
}
