// The upload engine over FakeUploadBackend: the replay-safety table, the registry, generations,
// grants and sign-out. No plugin, no disk.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download_background/fespalier_download_background.dart';
import 'package:fespalier_download_background/testing.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

const _safe = {'Idempotency-Key': 'k-1'};

UploadRequest req(
  String id, {
  bool safe = false,
  DownloadPriority priority = DownloadPriority.background,
}) => UploadRequest(
  id: id,
  url: Uri.parse('https://api.example.com/secret-$id'),
  file: DownloadLocation(DownloadBase.documents, 'outbox/$id.jpg'),
  headers: safe ? _safe : const {},
  priority: priority,
  displayName: 'Private name $id',
);

/// A registry whose calls fail when told to: a full disk, an unreadable file.
class FlakyStore extends MemoryUploadStore {
  FlakyStore([super.initial]);

  Object? failLoad;
  Object? failPut;
  Object? failRemove;

  @override
  Future<Map<String, StoredUpload>> load() async {
    final failure = failLoad;
    if (failure != null) throw failure;
    return super.load();
  }

  @override
  Future<void> put(StoredUpload upload) async {
    final failure = failPut;
    if (failure != null) throw failure;
    await super.put(upload);
  }

  @override
  Future<void> remove(String id) async {
    final failure = failRemove;
    if (failure != null) throw failure;
    await super.remove(id);
  }
}

class Rig {
  Rig({
    FakeUploadBackend? backend,
    MemoryUploadStore? store,
    UploadGrantor? grantor,
  }) : backend = backend ?? FakeUploadBackend(),
       store = store ?? MemoryUploadStore() {
    engine = Uploads(
      backend: this.backend,
      store: this.store,
      grantor: grantor,
    );
    engine.observe((id, s) => seen.add('$id $s'));
  }

  final FakeUploadBackend backend;
  final MemoryUploadStore store;
  late final Uploads engine;
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
      expect(r.store.entries.keys, ['a']);
      r.backend.emit('a', const Running(5, 10));
      r.backend.emit('a', Complete(req('a').file, 10));
      expect(r.engine.statusOf('a'), Complete(req('a').file, 10));
    });

    test('an invalid request fails early and is not registered', () async {
      final r = await opened();
      await r.engine.start(
        UploadRequest(
          id: 'a',
          url: Uri.parse('https://x.example.com/'),
          file: const DownloadLocation(DownloadBase.support, '../etc/passwd'),
        ),
      );
      expect(
        r.engine.statusOf('a'),
        const Failed(DownloadFailure.invalidRequest),
      );
      expect(r.backend.enqueued, isEmpty);
      expect(r.store.entries, isEmpty);
    });

    test(
      'before open it throws, and a running id is the same upload',
      () async {
        final r = Rig();
        expect(() => r.engine.start(req('a')), throwsStateError);
        await r.engine.open();
        await r.engine.start(req('a'));
        await r.engine.start(req('a'));
        expect(r.backend.enqueued, hasLength(1));
      },
    );

    test('user-initiated needs notifications', () async {
      final r = await opened();
      await r.engine.start(req('a', priority: DownloadPriority.userInitiated));
      expect(
        r.engine.statusOf('a'),
        const Failed(DownloadFailure.notificationsRequired),
      );
      final ok = await opened(
        Rig(
          backend: FakeUploadBackend(
            capabilities: const DownloadCapabilities(notifications: true),
          ),
        ),
      );
      await ok.engine.start(req('a', priority: DownloadPriority.userInitiated));
      expect(ok.engine.statusOf('a'), const Queued());
    });

    test('a backend that refuses ends Failed(other)', () async {
      final r = await opened(Rig(backend: FakeUploadBackend(accepts: false)));
      await r.engine.start(req('a'));
      expect(r.engine.statusOf('a'), const Failed(DownloadFailure.other));
    });

    test('an upload cannot be shown as paused', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', const Paused(1, 2));
      expect(r.engine.statusOf('a'), const Queued());
    });
  });

  group('replay safety', () {
    test(
      'after a restart an unmentioned upload is Failed(killed), never Complete',
      () async {
        for (final safe in [false, true]) {
          final store = MemoryUploadStore({
            'a': StoredUpload(req('a', safe: safe), generation: 2),
          });
          final r = await opened(Rig(store: store));
          expect(
            r.engine.statusOf('a'),
            const Failed(DownloadFailure.killed),
            reason: 'safe: $safe',
          );
          expect(r.backend.enqueued, isEmpty, reason: 'nothing is sent again');
        }
      },
    );

    test('what the platform kept is reported as it is', () async {
      final store = MemoryUploadStore({'a': StoredUpload(req('a'))});
      final r = await opened(
        Rig(
          store: store,
          backend: FakeUploadBackend(replay: {'a': Complete(req('a').file, 9)}),
        ),
      );
      expect(r.engine.statusOf('a'), Complete(req('a').file, 9));
    });

    test('a lost response of an upload without a key is outcomeUnknown and is not sent again', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', const Failed(DownloadFailure.network));
      expect(r.engine.outcomeUnknown('a'), isTrue);
      expect(await r.engine.retry('a'), isFalse);
      await r.engine.start(req('a'));
      expect(r.backend.enqueued, hasLength(1));
      expect(r.engine.statusOf('a'), const Failed(DownloadFailure.network));
    });

    test('so is a kill, and any other unknown end', () async {
      for (final failure in [
        DownloadFailure.killed,
        DownloadFailure.other,
        DownloadFailure.network,
      ]) {
        final r = await opened();
        await r.engine.start(req('a'));
        r.backend.emit('a', Failed(failure));
        expect(r.engine.outcomeUnknown('a'), isTrue, reason: '$failure');
        expect(await r.engine.retry('a'), isFalse, reason: '$failure');
      }
    });

    test('remove then start sends it again: the app\'s decision', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', const Failed(DownloadFailure.network));
      await r.engine.remove('a');
      expect(r.engine.statusOf('a'), const Absent());
      await r.engine.start(req('a'));
      expect(r.backend.enqueued, hasLength(2));
    });

    test(
      'a clear refusal is not an unknown outcome: it may be sent again',
      () async {
        for (final failure in [
          DownloadFailure.unauthorized,
          DownloadFailure.storage,
        ]) {
          final r = await opened();
          await r.engine.start(req('a'));
          r.backend.emit('a', Failed(failure));
          expect(r.engine.outcomeUnknown('a'), isFalse, reason: '$failure');
          expect(await r.engine.retry('a'), isTrue, reason: '$failure');
          expect(r.backend.enqueued, hasLength(2), reason: '$failure');
        }
        // A client error that proves nothing was applied stays `rejected`.
        for (final status in [400, 404, 405, 410, 413, 415, 422, 429]) {
          final r = await opened();
          await r.engine.start(req('a'));
          r.backend.emit(
            'a',
            const Failed(DownloadFailure.rejected),
            httpStatus: status,
          );
          expect(
            r.engine.statusOf('a'),
            const Failed(DownloadFailure.rejected),
            reason: '$status',
          );
          expect(r.engine.outcomeUnknown('a'), isFalse, reason: '$status');
          expect(await r.engine.retry('a'), isTrue, reason: '$status');
          expect(r.backend.enqueued, hasLength(2), reason: '$status');
        }
      },
    );

    test('a status the server may have processed is an unknown outcome and is not sent again', () async {
      // The write may have committed before a gateway or the server's own error handler
      // answered: 5xx, and 408 and 499, where the connection ended on a request in progress.
      for (final status in [408, 499, 500, 501, 502, 503, 504, 507, 520, 599]) {
        final r = await opened();
        await r.engine.start(req('a'));
        r.backend.emit(
          'a',
          const Failed(DownloadFailure.rejected),
          httpStatus: status,
        );
        expect(
          r.engine.statusOf('a'),
          const Failed(DownloadFailure.other),
          reason: '$status is not a refusal',
        );
        expect(r.engine.outcomeUnknown('a'), isTrue, reason: '$status');
        expect(await r.engine.retry('a'), isFalse, reason: '$status');
        await r.engine.start(req('a'));
        expect(r.backend.enqueued, hasLength(1), reason: '$status');
        expect(r.seen.last, 'a ${const Failed(DownloadFailure.other)}');
      }
    });

    test('a replay-safe upload may be sent again after a 5xx', () async {
      final r = await opened();
      await r.engine.start(req('a', safe: true));
      r.backend.emit(
        'a',
        const Failed(DownloadFailure.rejected),
        httpStatus: 504,
      );
      expect(r.engine.outcomeUnknown('a'), isFalse);
      expect(await r.engine.retry('a'), isTrue);
      expect(r.backend.enqueued, hasLength(2));
    });

    test('a replay-safe upload is retried after any failure', () async {
      final r = await opened();
      await r.engine.start(req('a', safe: true));
      r.backend.emit('a', const Failed(DownloadFailure.network));
      expect(r.engine.outcomeUnknown('a'), isFalse);
      expect(await r.engine.retry('a'), isTrue);
      expect(r.backend.enqueued, hasLength(2));
      r.backend.emit('a', const Failed(DownloadFailure.killed));
      await r.engine.start(req('a', safe: true));
      expect(r.backend.enqueued, hasLength(3));
    });

    test('retry does nothing for an upload that did not fail', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      expect(await r.engine.retry('a'), isFalse);
      expect(await r.engine.retry('zzz'), isFalse);
    });
  });

  group('the registry that remembers a write', () {
    // The registry is what says, after a restart, that an upload may have been sent. An upload
    // that was sent with no record of it would be sent again by `start`, unprotected.
    test(
      'an entry that cannot be saved: nothing is sent, Failed(storage)',
      () async {
        final store = FlakyStore()
          ..failPut = const UploadStoreException('full');
        final r = await opened(Rig(store: store));
        await r.engine.start(req('a'));
        expect(r.engine.statusOf('a'), const Failed(DownloadFailure.storage));
        expect(
          r.backend.enqueued,
          isEmpty,
          reason: 'it was never handed to the platform',
        );
        expect(store.entries, isEmpty);
        expect(
          r.engine.outcomeUnknown('a'),
          isFalse,
          reason: 'nothing was sent',
        );
        expect(r.seen.last, 'a ${const Failed(DownloadFailure.storage)}');
      },
    );

    test(
      'any error of the store is the same, and none of its text is kept',
      () async {
        final store = FlakyStore()..failPut = StateError('SECRET /data/x');
        final r = await opened(Rig(store: store));
        await r.engine.start(req('a'));
        expect(r.engine.statusOf('a'), const Failed(DownloadFailure.storage));
        expect(r.seen.join(), isNot(contains('SECRET')));
      },
    );

    test('it can be retried once the registry works', () async {
      final store = FlakyStore()..failPut = StateError('full');
      final r = await opened(Rig(store: store));
      await r.engine.start(req('a'));
      expect(await r.engine.retry('a'), isTrue, reason: 'it was never sent');
      expect(r.engine.statusOf('a'), const Failed(DownloadFailure.storage));
      store.failPut = null;
      expect(await r.engine.retry('a'), isTrue);
      expect(r.engine.statusOf('a'), const Queued());
      expect(r.backend.enqueued.single.id, 'a');
      expect(store.entries.keys, ['a']);
    });

    test('a registry that cannot be read: an upload without a key is not started, one with a key is', () async {
      final store = FlakyStore({'old': StoredUpload(req('old'))})
        ..failLoad = const UploadStoreException('unreadable');
      final r = Rig(store: store);
      await r.engine.open();
      expect(r.engine.isOpen, isTrue, reason: 'opening never throws');
      await r.engine.start(req('a'));
      expect(r.engine.statusOf('a'), const Failed(DownloadFailure.storage));
      expect(r.backend.enqueued, isEmpty);
      await r.engine.start(req('b', safe: true));
      expect(r.engine.statusOf('b'), const Queued());
      expect(r.backend.enqueued.single.id, 'b');
    });

    test('the two debug lines, as fespalier-troubleshooting quotes them', () async {
      final printed = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      addTearDown(() => debugPrint = original);

      final unsaved = await opened(
        Rig(store: FlakyStore()..failPut = StateError('SECRET /data/x')),
      );
      await unsaved.engine.start(req('a'));
      final unreadable = Rig(
        store: FlakyStore()
          ..failLoad = const UploadStoreException(
            'the registry file could not be read, or is not a registry this version knows',
          ),
      );
      await unreadable.engine.open();

      expect(printed, [
        'fespalier_download_background: an upload was not started, because its '
            'entry could not be saved in the registry (StateError): after a '
            'restart nothing would say it was sent',
        'fespalier_download_background: the uploads registry could not be loaded '
            '(the registry file could not be read, or is not a registry this '
            'version knows), so an upload without an Idempotency-Key is not '
            'started: it may have been sent before and nothing remembers it. '
            'Restart the app, or call clearAccount after asking your server what '
            'it received',
      ]);
      expect(printed.join(), isNot(contains('SECRET')));
    });

    test('clearAccount makes the registry count again', () async {
      final store = FlakyStore()..failLoad = StateError('unreadable');
      final r = Rig(store: store);
      await r.engine.open();
      store.failLoad = null;
      await r.engine.clearAccount();
      await r.engine.start(req('a'));
      expect(r.engine.statusOf('a'), const Queued());
    });

    test(
      'cancel, remove and clearAccount do not throw when the store does',
      () async {
        final store = FlakyStore();
        final r = await opened(Rig(store: store));
        await r.engine.start(req('a'));
        await r.engine.start(req('b'));
        store
          ..failRemove = StateError('x')
          ..failLoad = StateError('x');
        await r.engine.cancel('a');
        await r.engine.remove('b');
        await r.engine.clearAccount();
        expect(r.engine.statusOf('a'), const Absent());
        expect(r.engine.statusOf('b'), const Absent());
      },
    );
  });

  group('grants', () {
    test('a grant replaces the address and adds headers for one attempt, and is stored nowhere', () async {
      final r = await opened(
        Rig(
          grantor: (request, {required renewal}) => DownloadGrant(
            url: Uri.parse('https://cdn.example.com/signed-${request.id}'),
            headers: const {'X-Grant': 'g1'},
          ),
        ),
      );
      await r.engine.start(req('a'));
      expect(r.backend.enqueued.single.url.host, 'cdn.example.com');
      expect(r.backend.authorizations.single, {'X-Grant': 'g1'});
      expect(r.store.entries['a']!.request.url.host, 'api.example.com');
    });

    test('401 renews the grant once for a replay-safe upload', () async {
      final asked = <bool>[];
      final r = await opened(
        Rig(
          grantor: (request, {required renewal}) {
            asked.add(renewal);
            return DownloadGrant(headers: {'X-Grant': 'g${asked.length}'});
          },
        ),
      );
      await r.engine.start(req('a', safe: true));
      r.backend.emit(
        'a',
        const Failed(DownloadFailure.unauthorized),
        httpStatus: 401,
      );
      await pumpEventQueue();
      expect(asked, [false, true]);
      expect(r.backend.enqueued, hasLength(2));
      expect(r.backend.cancelled, ['a']);
      expect(r.backend.authorizations.last, {'X-Grant': 'g2'});
      r.backend.emit(
        'a',
        const Failed(DownloadFailure.unauthorized),
        httpStatus: 403,
      );
      await pumpEventQueue();
      expect(
        r.engine.statusOf('a'),
        const Failed(DownloadFailure.unauthorized),
      );
      expect(r.backend.enqueued, hasLength(2), reason: 'only one renewal');
    });

    test('401 never sends an upload without a key again', () async {
      var asked = 0;
      final r = await opened(
        Rig(
          grantor: (request, {required renewal}) {
            asked++;
            return null;
          },
        ),
      );
      await r.engine.start(req('a'));
      r.backend.emit(
        'a',
        const Failed(DownloadFailure.unauthorized),
        httpStatus: 401,
      );
      await pumpEventQueue();
      expect(asked, 1);
      expect(r.backend.enqueued, hasLength(1));
      expect(
        r.engine.statusOf('a'),
        const Failed(DownloadFailure.unauthorized),
      );
    });

    test(
      'a grantor that throws ends Failed(unauthorized) and nothing is sent',
      () async {
        final r = await opened(
          Rig(
            grantor: (request, {required renewal}) =>
                throw StateError('SECRET'),
          ),
        );
        await r.engine.start(req('a'));
        expect(
          r.engine.statusOf('a'),
          const Failed(DownloadFailure.unauthorized),
        );
        expect(r.backend.enqueued, isEmpty);
        expect(r.seen.join(), isNot(contains('SECRET')));
      },
    );

    test(
      'a grant that names an invalid address ends Failed(unauthorized)',
      () async {
        final r = await opened(
          Rig(
            grantor: (request, {required renewal}) =>
                DownloadGrant(url: Uri.parse('ftp://nope.example.com/x')),
          ),
        );
        await r.engine.start(req('a'));
        expect(
          r.engine.statusOf('a'),
          const Failed(DownloadFailure.unauthorized),
        );
      },
    );

    test('a cancel during the grant request wins', () async {
      final gate = Completer<DownloadGrant?>();
      final r = await opened(
        Rig(grantor: (request, {required renewal}) => gate.future),
      );
      final starting = r.engine.start(req('a'));
      await pumpEventQueue();
      await r.engine.cancel('a');
      gate.complete(null);
      await starting;
      expect(r.backend.enqueued, isEmpty);
      expect(r.engine.statusOf('a'), const Cancelled());
    });
  });

  group('cancel, remove and sign-out', () {
    test('cancel stops the transfer and drops the registry entry', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      await r.engine.cancel('a');
      expect(r.engine.statusOf('a'), const Cancelled());
      expect(r.backend.cancelled, ['a']);
      expect(r.store.entries, isEmpty);
    });

    test(
      'the platform cancelling it is the same as the app cancelling it',
      () async {
        final r = await opened();
        await r.engine.start(req('a'));
        r.backend.emit('a', const Cancelled());
        await pumpEventQueue();
        expect(r.engine.statusOf('a'), const Cancelled());
        expect(r.store.entries, isEmpty);
      },
    );

    test('a finished upload is not cancelled; remove forgets it', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', Complete(req('a').file, 1));
      await r.engine.cancel('a');
      expect(r.engine.statusOf('a'), isA<Complete>());
      await r.engine.remove('a');
      expect(r.engine.statusOf('a'), const Absent());
      expect(r.store.entries, isEmpty);
    });

    test('clearAccount cancels everything, wipes the registry and ignores late events', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      await r.engine.start(req('b', safe: true));
      await r.engine.clearAccount();
      expect(r.backend.cancelAllCalls, 1);
      expect(r.store.clearCalls, 1);
      expect(r.store.entries, isEmpty);
      expect(r.engine.statuses, isEmpty);
      r.backend.emit('a', const Running(1, 2));
      expect(r.engine.statusOf('a'), const Absent());
    });
  });

  group('the engine itself', () {
    test('a late event of an id the engine does not know is dropped', () async {
      final r = await opened();
      r.backend.emit('ghost', const Running(1, 2));
      expect(r.engine.statuses, isEmpty);
    });

    test('an observer that throws costs its own update', () async {
      final r = await opened();
      r.engine.observe((id, s) => throw StateError('boom'));
      await r.engine.start(req('a'));
      expect(r.engine.statusOf('a'), const Queued());
    });

    test('close clears the observer and is idempotent', () async {
      final r = await opened();
      await r.engine.close();
      await r.engine.close();
      expect(r.backend.isOpen, isFalse);
      expect(r.engine.isOpen, isFalse);
    });

    test('lastChange follows package:clock', () async {
      final r = await opened();
      expect(r.engine.lastChange, isNull);
      await r.engine.start(req('a'));
      expect(r.engine.lastChange, isNotNull);
    });

    test('a status carries no URL, id, path or name', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', Complete(req('a').file, 3));
      final text = r.seen.join('\n');
      for (final secret in [
        'secret-a',
        'Private name',
        'outbox',
        'api.example',
      ]) {
        expect(text, isNot(contains(secret)));
      }
    });
  });

  group('telemetry', () {
    late RecordingTelemetry rec;
    setUp(() {
      rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
    });
    tearDown(() => FespalierTelemetry.install(null));

    test('one span per upload, with constants only', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', Complete(req('a').file, 3));
      expect(
        rec.log.first,
        startsWith('#1 start custom fespalier.upload.transfer'),
      );
      expect(rec.log.last, startsWith('#1 end custom'));
      final text = rec.log.join('\n');
      for (final secret in [
        'secret-a',
        'Private name',
        'outbox',
        'api.example',
      ]) {
        expect(text, isNot(contains(secret)));
      }
    });

    test('a failure ends the span as an error with its name', () async {
      final r = await opened();
      await r.engine.start(req('a'));
      r.backend.emit('a', const Failed(DownloadFailure.network));
      expect(rec.log.join('\n'), contains('network'));
    });

    test(
      'an upload that ended while the app was away is one reconciled span',
      () async {
        final store = MemoryUploadStore({'a': StoredUpload(req('a'))});
        await opened(Rig(store: store));
        expect(
          rec.log.any((l) => l.contains('fespalier.upload.reconciled')),
          isTrue,
        );
      },
    );
  });
}
