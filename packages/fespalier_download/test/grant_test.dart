// The grant seam of the engine: a short-lived grant before each attempt, one renewed grant after a
// 401 or 403, and the generation rules around the foreground request that makes it.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _loc = DownloadLocation(DownloadBase.support, 'f/a.bin');

DownloadRequest _req([String id = 'a']) => DownloadRequest(
  id: id,
  url: Uri.parse('https://api.example.com/stable-$id'),
  file: DownloadLocation(DownloadBase.support, 'f/$id.bin'),
  bytes: 10,
);

DownloadGrant _grant(String n) => DownloadGrant(
  url: Uri.parse('https://cdn.example.com/$n'),
  headers: {'x-grant': n},
);

// A grantor the test answers one call at a time.
class _Grantor {
  final List<(String id, bool renewal)> calls = [];
  final List<Completer<DownloadGrant?>> _pending = [];

  Future<DownloadGrant?> call(DownloadRequest r, {required bool renewal}) {
    calls.add((r.id, renewal));
    final c = Completer<DownloadGrant?>();
    _pending.add(c);
    return c.future;
  }

  void answer(int call, DownloadGrant? grant) => _pending[call].complete(grant);

  void fail(int call) => _pending[call].completeError(StateError('boom'));
}

class _Rig {
  _Rig({DownloadGrantor? grantor}) {
    engine = Downloads(
      backend: backend,
      store: store,
      files: files,
      grantor: grantor,
    );
    engine.observe((id, s) => seen.add('$id ${s.runtimeType}'));
  }

  final backend = FakeDownloadBackend();
  final store = MemoryDownloadStore();
  final files = FakeDownloadFiles();
  late final Downloads engine;
  final List<String> seen = [];
}

Future<_Rig> _opened({DownloadGrantor? grantor}) async {
  final r = _Rig(grantor: grantor);
  await r.engine.open();
  return r;
}

void main() {
  group('the first grant', () {
    test(
      'is asked before the backend, its URL and headers are for that attempt only',
      () async {
        final g = _Grantor();
        final r = await _opened(grantor: g.call);
        final started = r.engine.start(_req());
        await pumpEventQueue();
        expect(g.calls, [('a', false)]);
        expect(r.backend.enqueued, isEmpty, reason: 'waits for the grant');
        g.answer(0, _grant('one'));
        await started;
        expect(r.backend.enqueued.single.url.path, '/one');
        expect(r.backend.enqueued.single.id, 'a');
        expect(r.backend.enqueued.single.bytes, 10);
        expect(r.backend.authorizations.single, {'x-grant': 'one'});
        expect(
          r.store.entries['a']!.request.url.path,
          '/stable-a',
          reason: 'the registry keeps the request, never the capability',
        );
      },
    );

    test('null sends the request as it is', () async {
      final g = _Grantor();
      final r = await _opened(grantor: g.call);
      final started = r.engine.start(_req());
      await pumpEventQueue();
      g.answer(0, null);
      await started;
      expect(r.backend.enqueued.single.url.path, '/stable-a');
      expect(r.backend.authorizations.single, isEmpty);
    });

    test('headers alone leave the address', () async {
      final g = _Grantor();
      final r = await _opened(grantor: g.call);
      final started = r.engine.start(_req());
      await pumpEventQueue();
      g.answer(0, const DownloadGrant(headers: {'x-only': '1'}));
      await started;
      expect(r.backend.enqueued.single.url.path, '/stable-a');
      expect(r.backend.authorizations.single, {'x-only': '1'});
    });

    test('a grantor that throws ends Failed(unauthorized), no crash', () async {
      final g = _Grantor();
      final r = await _opened(grantor: g.call);
      final started = r.engine.start(_req());
      await pumpEventQueue();
      g.fail(0);
      await started;
      expect(
        r.engine.statusOf('a'),
        const Failed(DownloadFailure.unauthorized),
      );
      expect(r.backend.enqueued, isEmpty);
    });

    test('a grantor that throws at once is the same', () async {
      final r = await _opened(
        grantor: (request, {required renewal}) => throw StateError('sync'),
      );
      await r.engine.start(_req());
      expect(
        r.engine.statusOf('a'),
        const Failed(DownloadFailure.unauthorized),
      );
      expect(r.backend.enqueued, isEmpty);
    });

    test('a grant whose URL is not usable ends Failed(unauthorized)', () async {
      final r = await _opened(
        grantor: (request, {required renewal}) =>
            DownloadGrant(url: Uri.parse('ftp://cdn.example.com/x')),
      );
      await r.engine.start(_req());
      expect(
        r.engine.statusOf('a'),
        const Failed(DownloadFailure.unauthorized),
      );
      expect(r.backend.enqueued, isEmpty);
    });

    test('retry asks again, and its failure is allowed one renewal', () async {
      var n = 0;
      final r = await _opened(
        grantor: (request, {required renewal}) =>
            DownloadGrant(url: Uri.parse('https://cdn.example.com/g${n++}')),
      );
      await r.engine.start(_req());
      r.backend.emit(
        'a',
        const Failed(DownloadFailure.unauthorized),
        httpStatus: 401,
      );
      await pumpEventQueue();
      r.backend.emit(
        'a',
        const Failed(DownloadFailure.unauthorized),
        httpStatus: 401,
      );
      expect(
        r.engine.statusOf('a'),
        const Failed(DownloadFailure.unauthorized),
      );
      expect(n, 2);
      await r.engine.retry('a');
      r.backend.emit(
        'a',
        const Failed(DownloadFailure.unauthorized),
        httpStatus: 403,
      );
      await pumpEventQueue();
      expect(n, 4, reason: 'a retry (1) and its one renewal (1)');
      expect(r.engine.statusOf('a'), isA<Queued>());
    });

    test('resume sends the grant headers and keeps the address', () async {
      final g = _Grantor();
      final r = await _opened(grantor: g.call);
      final started = r.engine.start(_req());
      await pumpEventQueue();
      g.answer(0, _grant('one'));
      await started;
      r.backend.emit('a', const Paused(1, 10));
      final resumed = r.engine.resume('a');
      await pumpEventQueue();
      expect(g.calls.last, ('a', false));
      g.answer(1, _grant('two'));
      expect(await resumed, isTrue);
      expect(r.backend.resumed, ['a']);
      expect(r.backend.authorizations.last, {'x-grant': 'two'});
    });
  });

  group('after a 401 or 403', () {
    for (final code in [401, 403]) {
      test(
        '$code asks once more and enqueues again with the new grant',
        () async {
          final g = _Grantor();
          final r = await _opened(grantor: g.call);
          final started = r.engine.start(_req());
          await pumpEventQueue();
          g.answer(0, _grant('one'));
          await started;
          r.backend.emit('a', const Running(4, 10));
          r.backend.emit(
            'a',
            const Failed(DownloadFailure.unauthorized),
            httpStatus: code,
          );
          expect(
            r.engine.statusOf('a'),
            isA<Queued>(),
            reason: 'not failed while the renewal is asked',
          );
          await pumpEventQueue();
          expect(g.calls, [('a', false), ('a', true)]);
          g.answer(1, _grant('two'));
          await pumpEventQueue();
          expect(r.backend.cancelled, ['a']);
          expect(r.backend.enqueued.map((e) => e.url.path), ['/one', '/two']);
          expect(r.backend.authorizations.last, {'x-grant': 'two'});
          r.backend.emit('a', Complete(_req().file, 10));
          expect(r.engine.statusOf('a'), Complete(_req().file, 10));
          expect(r.seen, isNot(contains('a Failed')));
        },
      );
    }

    test(
      'a second refusal ends Failed(unauthorized), no third grant',
      () async {
        final g = _Grantor();
        final r = await _opened(grantor: g.call);
        final started = r.engine.start(_req());
        await pumpEventQueue();
        g.answer(0, _grant('one'));
        await started;
        r.backend.emit(
          'a',
          const Failed(DownloadFailure.unauthorized),
          httpStatus: 401,
        );
        await pumpEventQueue();
        g.answer(1, _grant('two'));
        await pumpEventQueue();
        r.backend.emit(
          'a',
          const Failed(DownloadFailure.unauthorized),
          httpStatus: 401,
        );
        await pumpEventQueue();
        expect(
          r.engine.statusOf('a'),
          const Failed(DownloadFailure.unauthorized),
        );
        expect(g.calls, hasLength(2));
        expect(r.backend.enqueued, hasLength(2));
      },
    );

    test(
      'a grantor that throws during the renewal ends Failed(unauthorized)',
      () async {
        final g = _Grantor();
        final r = await _opened(grantor: g.call);
        final started = r.engine.start(_req());
        await pumpEventQueue();
        g.answer(0, _grant('one'));
        await started;
        r.backend.emit(
          'a',
          const Failed(DownloadFailure.unauthorized),
          httpStatus: 401,
        );
        await pumpEventQueue();
        g.fail(1);
        await pumpEventQueue();
        expect(
          r.engine.statusOf('a'),
          const Failed(DownloadFailure.unauthorized),
        );
        expect(r.backend.enqueued, hasLength(1));
      },
    );

    test('a refusal without a grantor is final, as before', () async {
      final r = await _opened();
      await r.engine.start(_req());
      r.backend.emit(
        'a',
        const Failed(DownloadFailure.rejected),
        httpStatus: 403,
      );
      expect(
        r.engine.statusOf('a'),
        const Failed(DownloadFailure.unauthorized),
      );
      expect(r.backend.enqueued, hasLength(1));
    });

    test('another failure is not a refusal', () async {
      final g = _Grantor();
      final r = await _opened(grantor: g.call);
      final started = r.engine.start(_req());
      await pumpEventQueue();
      g.answer(0, null);
      await started;
      r.backend.emit(
        'a',
        const Failed(DownloadFailure.rejected),
        httpStatus: 404,
      );
      expect(r.engine.statusOf('a'), const Failed(DownloadFailure.rejected));
      expect(g.calls, hasLength(1));
    });

    group('a newer state wins over the grant request', () {
      Future<(_Rig, _Grantor)> refused() async {
        final g = _Grantor();
        final r = await _opened(grantor: g.call);
        final started = r.engine.start(_req());
        await pumpEventQueue();
        g.answer(0, _grant('one'));
        await started;
        r.backend.emit(
          'a',
          const Failed(DownloadFailure.unauthorized),
          httpStatus: 401,
        );
        await pumpEventQueue();
        expect(g.calls.last, ('a', true));
        return (r, g);
      }

      test('cancel', () async {
        final (r, g) = await refused();
        await r.engine.cancel('a');
        g.answer(1, _grant('late'));
        await pumpEventQueue();
        expect(r.engine.statusOf('a'), const Cancelled());
        expect(r.backend.enqueued, hasLength(1));
        expect(r.store.entries, isEmpty);
      });

      test('a grant that throws after a cancel stays cancelled', () async {
        final (r, g) = await refused();
        await r.engine.cancel('a');
        g.fail(1);
        await pumpEventQueue();
        expect(r.engine.statusOf('a'), const Cancelled());
      });

      test('remove', () async {
        final (r, g) = await refused();
        await r.engine.remove('a');
        g.answer(1, _grant('late'));
        await pumpEventQueue();
        expect(r.engine.statusOf('a'), const Absent());
        expect(r.backend.enqueued, hasLength(1));
      });

      test('sign-out', () async {
        final (r, g) = await refused();
        await r.engine.clearAccount();
        g.answer(1, _grant('late'));
        await pumpEventQueue();
        expect(r.engine.statuses, isEmpty);
        expect(r.backend.enqueued, hasLength(1));
      });

      test('a restart: only the new attempt reaches the backend', () async {
        final (r, g) = await refused();
        await r.engine.cancel('a');
        final again = r.engine.start(_req());
        await pumpEventQueue();
        expect(g.calls.last, ('a', false));
        g.answer(1, _grant('stale'));
        g.answer(2, _grant('fresh'));
        await again;
        await pumpEventQueue();
        expect(r.backend.enqueued.map((e) => e.url.path), ['/one', '/fresh']);
        expect(r.engine.statusOf('a'), isA<Queued>());
      });
    });
  });

  group('a grant is a secret', () {
    test('toString prints no field', () {
      final grant = DownloadGrant(
        url: Uri.parse('https://cdn.example.com/secret-token'),
        headers: const {'authorization': 'Bearer hunter2'},
      );
      expect('$grant', 'DownloadGrant');
      expect('$grant', isNot(contains('secret')));
      expect('$grant', isNot(contains('hunter2')));
    });

    test('applyTo keeps the download and swaps the address', () {
      final request = DownloadRequest(
        id: 'a',
        url: Uri.parse('https://api.example.com/a'),
        file: _loc,
        headers: const {'x-a': '1'},
        bytes: 5,
        sha256: 'a' * 64,
        network: DownloadNetwork.unmetered,
        priority: DownloadPriority.userInitiated,
        displayName: 'n',
      );
      final out = _grant('z').applyTo(request);
      expect(out.url.path, '/z');
      expect(out.id, 'a');
      expect(out.file, _loc);
      expect(out.headers, {'x-a': '1'});
      expect(out.bytes, 5);
      expect(out.sha256, 'a' * 64);
      expect(out.network, DownloadNetwork.unmetered);
      expect(out.priority, DownloadPriority.userInitiated);
      expect(out.displayName, 'n');
      expect(const DownloadGrant().applyTo(request), same(request));
    });
  });

  group('telemetry', () {
    test('a renewed transfer says so, and nothing else', () async {
      final rec = _Sink();
      FespalierTelemetry.install(rec);
      addTearDown(() => FespalierTelemetry.install(null));
      var n = 0;
      final r = await _opened(
        grantor: (request, {required renewal}) =>
            DownloadGrant(url: Uri.parse('https://cdn.example.com/g${n++}')),
      );
      await r.engine.start(_req());
      r.backend.emit(
        'a',
        const Failed(DownloadFailure.unauthorized),
        httpStatus: 401,
      );
      await pumpEventQueue();
      r.backend.emit('a', Complete(_req().file, 10));
      await r.engine.start(_req('b'));
      r.backend.emit('b', Complete(_req('b').file, 10));
      expect(rec.ends, hasLength(2));
      expect(rec.ends[0].attributes, {
        FespalierDownloadConventions.result: 'complete',
        FespalierDownloadConventions.regranted: true,
      });
      expect(rec.ends[1].attributes, {
        FespalierDownloadConventions.result: 'complete',
      });
      final all = rec.ends.expand((e) => (e.attributes ?? {}).values).join(' ');
      expect(all, isNot(contains('cdn')));
    });

    test('a second refusal is a failed, renewed transfer', () async {
      final rec = _Sink();
      FespalierTelemetry.install(rec);
      addTearDown(() => FespalierTelemetry.install(null));
      final r = await _opened(
        grantor: (request, {required renewal}) => const DownloadGrant(),
      );
      await r.engine.start(_req());
      for (var i = 0; i < 2; i++) {
        r.backend.emit(
          'a',
          const Failed(DownloadFailure.unauthorized),
          httpStatus: 401,
        );
        await pumpEventQueue();
      }
      expect(rec.ends.single.attributes, {
        FespalierDownloadConventions.result: 'failed',
        FespalierDownloadConventions.failure: 'unauthorized',
        FespalierDownloadConventions.regranted: true,
      });
    });
  });
}

class _Sink extends FespalierTelemetry {
  final List<TelemetryEnd> ends = [];
  int _n = 0;

  @override
  Object? start(TelemetryStart start) => ++_n;

  @override
  void end(Object? token, TelemetryEnd end) => ends.add(end);
}
