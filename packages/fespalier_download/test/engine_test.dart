import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _loc = DownloadLocation(DownloadBase.support, 'f/a.bin');

DownloadRequest req(
  String id, {
  DownloadPriority priority = DownloadPriority.background,
  int? bytes,
  DownloadLocation? file,
}) => DownloadRequest(
  id: id,
  url: Uri.parse('https://example.com/secret-$id'),
  file: file ?? DownloadLocation(DownloadBase.support, 'f/$id.bin'),
  priority: priority,
  bytes: bytes,
  displayName: 'Private name $id',
);

class Rig {
  Rig({
    FakeDownloadBackend? backend,
    MemoryDownloadStore? store,
    FakeDownloadFiles? files,
  }) : backend = backend ?? FakeDownloadBackend(),
       store = store ?? MemoryDownloadStore(),
       files = files ?? FakeDownloadFiles() {
    engine = Downloads(
      backend: this.backend,
      store: this.store,
      files: this.files,
    );
    engine.observe((id, s) => seen.add('$id ${s.runtimeType}'));
  }

  final FakeDownloadBackend backend;
  final MemoryDownloadStore store;
  final FakeDownloadFiles files;
  late final Downloads engine;
  final List<String> seen = [];
}

Future<Rig> opened([Rig? rig]) async {
  final r = rig ?? Rig();
  await r.engine.open();
  return r;
}

void main() {
  group('start', () {
    test('queues, registers and hands the request to the backend', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      expect(r.engine.statusOf('a'), const Queued());
      expect(r.backend.enqueued.single.id, 'a');
      expect(r.store.entries['a']!.request.id, 'a');
      expect(r.store.entries['a']!.generation, 1);
      expect(r.engine.statuses, {'a': const Queued()});
    });

    test('the same id again is the same download', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      await r.engine.start(req('a'));
      expect(r.backend.enqueued, hasLength(1));
      r.backend.emit('a', const Complete(_loc, 5));
      await r.engine.start(req('a'));
      expect(r.backend.enqueued, hasLength(1));
    });

    test('before open it is a StateError, a programming mistake', () async {
      final r = Rig();
      expect(() => r.engine.start(req('a')), throwsStateError);
    });

    test(
      'an invalid request is Failed, never a throw, never registered',
      () async {
        final r = await opened();
        final bad = DownloadRequest(
          id: 'bad',
          url: Uri.parse('file:///etc/passwd'),
          file: _loc,
        );
        await r.engine.start(bad);
        expect(
          r.engine.statusOf('bad'),
          const Failed(DownloadFailure.invalidRequest),
        );
        await r.engine.start(
          req('p', file: const DownloadLocation(DownloadBase.support, '../x')),
        );
        expect(
          r.engine.statusOf('p'),
          const Failed(DownloadFailure.invalidRequest),
        );
        await r.engine.start(req('', bytes: 1));
        expect(r.backend.enqueued, isEmpty);
        expect(r.store.entries, isEmpty);
        // retry has no request to repeat.
        await r.engine.retry('bad');
        expect(r.backend.enqueued, isEmpty);
      },
    );

    test(
      'userInitiated without notifications ends notificationsRequired',
      () async {
        final r = await opened();
        await r.engine.start(
          req('u', priority: DownloadPriority.userInitiated),
        );
        expect(
          r.engine.statusOf('u'),
          const Failed(DownloadFailure.notificationsRequired),
        );
        expect(r.backend.enqueued, isEmpty);

        final withNotifications = await opened(
          Rig(
            backend: FakeDownloadBackend(
              capabilities: const DownloadCapabilities(
                pause: true,
                notifications: true,
                userInitiated: true,
              ),
            ),
          ),
        );
        await withNotifications.engine.start(
          req('u', priority: DownloadPriority.userInitiated),
        );
        expect(withNotifications.engine.statusOf('u'), const Queued());
      },
    );

    test('a backend that refuses ends Failed(other)', () async {
      final r = await opened(Rig(backend: FakeDownloadBackend(accepts: false)));
      await r.engine.start(req('a'));
      expect(r.engine.statusOf('a'), const Failed(DownloadFailure.other));
    });
  });

  group('transitions', () {
    test(
      'every status the backend reports reaches the observer and statusOf',
      () async {
        final r = await opened();
        await r.engine.start(req('a'));
        final steps = <DownloadStatus>[
          const Waiting(WaitReason.network),
          const Running(0, 10),
          const Running(5, 10),
          const Paused(5, 10),
          const Running(6, 10),
          const Verifying(),
          const Complete(_loc, 10),
        ];
        for (final step in steps) {
          r.backend.emit('a', step);
          expect(r.engine.statusOf('a'), step);
        }
        expect(r.seen.first, 'a Queued');
        expect(r.seen, hasLength(steps.length + 1));
        expect(r.engine.lastChange, isNotNull);
      },
    );

    test('an equal status is not reported twice', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', const Running(1, 2));
      r.backend.emit('a', const Running(1, 2));
      expect(r.seen, ['a Queued', 'a Running']);
    });

    test('lastChange reads package:clock', () async {
      final r = await opened();
      final moment = DateTime.utc(2030, 1, 2);
      await withClock(Clock.fixed(moment), () async {
        await r.engine.start(req('a'));
      });
      expect(r.engine.lastChange, moment);
    });

    test(
      '401 and 403 end unauthorized, other errors keep their failure',
      () async {
        final r = await opened();
        await r.engine.start(req('a'));
        r.backend.emit(
          'a',
          const Failed(DownloadFailure.rejected),
          httpStatus: 403,
        );
        expect(
          r.engine.statusOf('a'),
          const Failed(DownloadFailure.unauthorized),
        );
        await r.engine.start(req('b'));
        r.backend.emit(
          'b',
          const Failed(DownloadFailure.rejected),
          httpStatus: 404,
        );
        expect(r.engine.statusOf('b'), const Failed(DownloadFailure.rejected));
      },
    );

    test('an event for an unknown id is dropped', () async {
      final r = await opened();
      r.backend.emit('ghost', const Running(1));
      expect(r.engine.statuses, isEmpty);
      expect(r.seen, isEmpty);
    });

    test('an event after the end is dropped', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', const Complete(_loc, 3));
      r.backend.emit('a', const Running(1));
      expect(r.engine.statusOf('a'), const Complete(_loc, 3));
    });

    test('an observer that throws costs only its own update', () async {
      final r = await opened();
      r.engine.observe((_, _) => throw StateError('boom'));
      await r.engine.start(req('a'));
      expect(r.engine.statusOf('a'), const Queued());
    });
  });

  group('pause, resume, retry', () {
    test('pause asks the backend and waits for its report', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', const Running(2, 9));
      expect(await r.engine.pause('a'), isTrue);
      expect(r.backend.paused, ['a']);
      expect(r.engine.statusOf('a'), const Running(2, 9));
      r.backend.emit('a', const Paused(2, 9));
      expect(await r.engine.resume('a'), isTrue);
      expect(r.backend.resumed, ['a']);
      expect(r.engine.statusOf('a'), const Queued());
    });

    test('pause is false when idle, unknown or unsupported', () async {
      final r = await opened();
      expect(await r.engine.pause('nope'), isFalse);
      expect(await r.engine.resume('nope'), isFalse);
      final np = await opened(
        Rig(
          backend: FakeDownloadBackend(
            capabilities: const DownloadCapabilities(),
          ),
        ),
      );
      await np.engine.start(req('a'));
      expect(await np.engine.pause('a'), isFalse);
      expect(np.backend.paused, isEmpty);
    });

    test('resume that the backend refuses leaves it paused', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', const Paused(1));
      r.backend.accepts = false;
      expect(await r.engine.resume('a'), isFalse);
      expect(r.engine.statusOf('a'), const Paused(1));
    });

    test(
      'retry starts a failed download again under a new generation',
      () async {
        final r = await opened();
        await r.engine.start(req('a'));
        r.backend.emit('a', const Failed(DownloadFailure.network));
        await r.engine.retry('a');
        expect(r.engine.statusOf('a'), const Queued());
        expect(r.backend.enqueued, hasLength(2));
        expect(r.backend.cancelled, ['a']);
        expect(r.store.entries['a']!.generation, 2);
      },
    );

    test(
      'retry after a mismatch deletes the file, after a network failure it does not',
      () async {
        final r = await opened();
        await r.engine.start(req('a'));
        r.backend.emit('a', const Failed(DownloadFailure.hashMismatch));
        await r.engine.retry('a');
        expect(r.files.deleted, [req('a').file]);
        r.backend.emit('a', const Failed(DownloadFailure.network));
        await r.engine.retry('a');
        expect(r.files.deleted, hasLength(1));
      },
    );

    test('retry does nothing unless Failed', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      await r.engine.retry('a');
      await r.engine.retry('nope');
      expect(r.backend.enqueued, hasLength(1));
    });
  });

  group('cancel and remove', () {
    test(
      'cancel drops the registry, deletes the partial and ends Cancelled',
      () async {
        final r = await opened();
        await r.engine.start(req('a'));
        await r.engine.cancel('a');
        expect(r.engine.statusOf('a'), const Cancelled());
        expect(r.backend.cancelled, ['a']);
        expect(r.store.entries, isEmpty);
        expect(r.files.deleted, [req('a').file]);
        expect(r.seen.last, 'a Cancelled');
      },
    );

    test('cancel leaves a finished download alone', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', const Complete(_loc, 3));
      await r.engine.cancel('a');
      expect(r.engine.statusOf('a'), const Complete(_loc, 3));
      expect(r.files.deleted, isEmpty);
    });

    test('remove deletes the file and the entry and ends Absent', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', Complete(req('a').file, 3));
      r.files.put(req('a').file, 3);
      await r.engine.remove('a');
      expect(r.engine.statusOf('a'), const Absent());
      expect(r.engine.statuses, isEmpty);
      expect(r.files.sizes, isEmpty);
      expect(r.store.entries, isEmpty);
      expect(r.seen.last, 'a Absent');
      await r.engine.remove('a');
    });

    test('a stale event after cancel, remove and restart is dropped', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      await r.engine.cancel('a');
      r.backend.emit('a', const Running(9));
      r.backend.emit('a', const Complete(_loc, 9));
      expect(r.engine.statusOf('a'), const Cancelled());

      await r.engine.start(req('b'));
      await r.engine.remove('b');
      r.backend.emit('b', const Running(1));
      expect(r.engine.statusOf('b'), const Absent());

      // Restart: the old attempt ended, the new one is live and takes events again.
      await r.engine.start(req('a'));
      expect(r.engine.statusOf('a'), const Queued());
      r.backend.emit('a', const Running(1, 4));
      expect(r.engine.statusOf('a'), const Running(1, 4));
      expect(r.store.entries['a']!.generation, 3);
    });

    test(
      'an await that finishes after a cancel does not write over it',
      () async {
        final slow = _SlowEnqueue();
        final r = await opened(Rig(backend: slow));
        final starting = r.engine.start(req('a'));
        await pumpEventQueue(times: 1);
        await r.engine.cancel('a');
        slow.release.complete(false);
        await starting;
        expect(r.engine.statusOf('a'), const Cancelled());
      },
    );

    test(
      'a cancel the platform reports (a notification action) is a cancel',
      () async {
        final r = await opened();
        await r.engine.start(req('a'));
        r.backend.emit('a', const Cancelled());
        await pumpEventQueue();
        expect(r.engine.statusOf('a'), const Cancelled());
        expect(r.store.entries, isEmpty);
      },
    );
  });

  group('pathOf', () {
    test(
      'only a Complete download has a path, and it is resolved now',
      () async {
        final r = await opened();
        await r.engine.start(req('a'));
        expect(await r.engine.pathOf('a'), isNull);
        expect(await r.engine.pathOf('nope'), isNull);
        r.backend.emit('a', Complete(req('a').file, 3));
        expect(await r.engine.pathOf('a'), '/fake/support/f/a.bin');
      },
    );
  });

  group('after a restart', () {
    test(
      'a new engine over the same store settles what ended while closed',
      () async {
        final store = MemoryDownloadStore();
        final first = await opened(Rig(store: store));
        for (final id in ['done', 'broke', 'going', 'gone', 'lost']) {
          await first.engine.start(req(id, bytes: id == 'lost' ? 7 : null));
        }
        await first.engine.close();

        final files = FakeDownloadFiles({req('gone').file: 4});
        files.put(req('lost').file, 3); // wrong size
        final backend = FakeDownloadBackend(
          replay: {
            'done': Complete(req('done').file, 10),
            'broke': const Failed(DownloadFailure.hashMismatch),
            'going': const Running(5, 20),
            'stranger': const Running(1),
          },
        );
        final rig = Rig(backend: backend, store: store, files: files);
        final rec = RecordingTelemetry();
        FespalierTelemetry.install(rec);
        addTearDown(() => FespalierTelemetry.install(null));
        await rig.engine.open();

        expect(rig.engine.statusOf('done'), Complete(req('done').file, 10));
        expect(
          rig.engine.statusOf('broke'),
          const Failed(DownloadFailure.hashMismatch),
        );
        expect(rig.engine.statusOf('going'), const Running(5, 20));
        expect(rig.engine.statusOf('gone'), Complete(req('gone').file, 4));
        expect(
          rig.engine.statusOf('lost'),
          const Failed(DownloadFailure.killed),
        );
        expect(rig.engine.statusOf('stranger'), const Absent());

        final reconciled = rec.log
            .where(
              (String l) =>
                  l.contains('start custom fespalier.download.reconciled'),
            )
            .length;
        expect(reconciled, 4);
        // The running one has a transfer span that went on from bytes it had.
        expect(
          rec.log.where(
            (String l) => l.contains('fespalier.download.transfer'),
          ),
          isNotEmpty,
        );
        expect(
          rec.log.any(
            (String l) =>
                l.contains('fespalier.download.resumed') && l.contains('true'),
          ),
          isTrue,
        );
        // It is the registry that survives: a completed download keeps its entry.
        expect(store.entries.keys, containsAll(['done', 'going', 'gone']));
      },
    );

    test('open twice does the work once', () async {
      final r = Rig();
      await r.engine.open();
      await r.engine.open();
      expect(r.engine.isOpen, isTrue);
    });
  });

  group('clearAccount', () {
    test(
      'cancels everything, deletes files and registry, drops later events',
      () async {
        final r = await opened();
        await r.engine.start(req('a'));
        await r.engine.start(req('b'));
        r.backend.emit('b', Complete(req('b').file, 3));
        r.files.put(req('b').file, 3);
        r.seen.clear();
        await r.engine.clearAccount();

        expect(r.backend.cancelAllCalls, 1);
        expect(r.store.entries, isEmpty);
        expect(r.store.clearCalls, 1);
        expect(r.files.deleted, containsAll([req('a').file, req('b').file]));
        expect(r.engine.statuses, isEmpty);
        expect(r.seen, unorderedEquals(['a Absent', 'b Absent']));

        r.backend.emit('a', const Running(1));
        r.backend.emit('b', const Complete(_loc, 1));
        expect(r.engine.statuses, isEmpty);
      },
    );

    test(
      'also removes registry entries the engine had not loaded statuses for',
      () async {
        final store = MemoryDownloadStore({'x': StoredDownload(req('x'))});
        final r = Rig(store: store);
        await r.engine.clearAccount();
        expect(store.entries, isEmpty);
        expect(r.files.deleted, [req('x').file]);
      },
    );

    test('an in-flight start of the old account does not survive it', () async {
      final slow = _SlowEnqueue();
      final r = await opened(Rig(backend: slow));
      final starting = r.engine.start(req('a'));
      await pumpEventQueue(times: 1);
      await r.engine.clearAccount();
      slow.release.complete(true);
      await starting;
      expect(r.engine.statusOf('a'), const Absent());
    });
  });

  group('observer', () {
    test('a second observe replaces the first; close clears it', () async {
      final r = Rig();
      await r.engine.open();
      final first = <String>[];
      final second = <String>[];
      r.engine.observe((id, s) => first.add(id));
      r.engine.observe((id, s) => second.add(id));
      await r.engine.start(req('a'));
      expect(first, isEmpty);
      expect(second, ['a']);
      await r.engine.close();
      expect(r.backend.isOpen, isFalse);
      expect(r.engine.isOpen, isFalse);
      // A leak test: nothing the closed engine does reaches the old owner.
      await r.engine.open();
      await r.engine.start(req('b'));
      expect(second, ['a']);
      r.backend.emit('b', const Running(1));
      expect(second, ['a']);
    });

    test('observe(null) clears it', () async {
      final r = await opened();
      r.engine.observe(null);
      await r.engine.start(req('a'));
      expect(r.seen, isEmpty);
    });
  });

  group('telemetry', () {
    const names = {
      FespalierDownloadConventions.transfer,
      FespalierDownloadConventions.reconciled,
    };
    final keys = {
      FespalierDownloadConventions.resumed,
      FespalierDownloadConventions.background,
      FespalierDownloadConventions.network,
      FespalierDownloadConventions.priority,
      FespalierDownloadConventions.result,
      FespalierDownloadConventions.failure,
    };
    final values = <Object>{
      true,
      false,
      ...DownloadNetwork.values.map((v) => v.name),
      ...DownloadPriority.values.map((v) => v.name),
      ...DownloadFailure.values.map((v) => v.name),
      FespalierDownloadConventions.resultComplete,
      FespalierDownloadConventions.resultFailed,
      FespalierDownloadConventions.resultCancelled,
    };

    test('every string a sink receives is a known constant', () async {
      final sink = _Sink();
      FespalierTelemetry.install(sink);
      addTearDown(() => FespalierTelemetry.install(null));
      final r = await opened();
      await r.engine.start(req('secret-id', bytes: 3));
      r.backend.emit('secret-id', const Running(1, 3));
      r.backend.emit('secret-id', Complete(req('secret-id').file, 3));
      await r.engine.start(req('f'));
      r.backend.emit('f', const Failed(DownloadFailure.hashMismatch));
      await r.engine.retry('f');
      await r.engine.cancel('f');
      await r.engine.start(req('g'));
      await r.engine.remove('g');

      expect(sink.starts, hasLength(4));
      for (final start in sink.starts) {
        expect(names, contains(start.name));
        expect(start.op, TelemetryOp.custom);
        for (final e in (start.attributes ?? {}).entries) {
          expect(keys, contains(e.key));
          expect(values, contains(e.value));
        }
      }
      expect(sink.ends, hasLength(4));
      for (final end in sink.ends) {
        for (final e in (end.attributes ?? {}).entries) {
          expect(keys, contains(e.key));
          expect(values, contains(e.value));
        }
        expect(end.error, isNull);
      }
      final results = sink.ends.map(
        (e) => e.attributes![FespalierDownloadConventions.result],
      );
      expect(results, ['complete', 'failed', 'cancelled', 'cancelled']);
      final all = [
        ...sink.starts.expand(
          (s) => [s.name, ...?s.attributes?.values.map((v) => '$v')],
        ),
        ...sink.ends.expand(
          (s) => (s.attributes ?? {}).values.map((v) => '$v'),
        ),
      ].join(' ');
      for (final secret in ['secret', 'Private', 'example.com', 'f/', '.bin']) {
        expect(all, isNot(contains(secret)));
      }
    });

    test('a sink that throws costs the span, never the download', () async {
      FespalierTelemetry.install(_Throwing());
      addTearDown(() => FespalierTelemetry.install(null));
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', Complete(req('a').file, 1));
      expect(r.engine.statusOf('a'), Complete(req('a').file, 1));
    });
  });

  test('the engine does not import Riverpod', () {
    final source = File('lib/src/engine.dart').readAsStringSync();
    expect(source, isNot(contains('riverpod')));
    expect(source, isNot(contains('flutter_hooks')));
    expect(source, isNot(contains('package:flutter/')));
  });
}

class _SlowEnqueue extends FakeDownloadBackend {
  final release = Completer<bool>();

  @override
  Future<bool> enqueue(
    DownloadRequest request, {
    Map<String, String> authorization = const {},
  }) {
    enqueued.add(request);
    return release.future;
  }
}

class _Sink extends FespalierTelemetry {
  final List<TelemetryStart> starts = [];
  final List<TelemetryEnd> ends = [];

  @override
  Object? start(TelemetryStart start) {
    starts.add(start);
    return starts.length;
  }

  @override
  void end(Object? token, TelemetryEnd end) => ends.add(end);
}

class _Throwing extends FespalierTelemetry {
  @override
  Object? start(TelemetryStart start) => throw StateError('sink down');

  @override
  void end(Object? token, TelemetryEnd end) => throw StateError('sink down');
}
