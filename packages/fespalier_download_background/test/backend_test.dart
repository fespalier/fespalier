// The backend's logic, driven through FakeBackgroundTransport: no plugin, no device. What an
// operating system decides is not here (see the README: "What no test shows").
import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:fespalier_download_background/fespalier_download_background.dart';
import 'package:fespalier_download_background/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _group = backgroundDownloadGroup;
const _location = DownloadLocation(DownloadBase.support, 'maps/a.bin');

final class Events implements DownloadEvents {
  final List<(String, DownloadStatus, int?)> seen = [];
  final List<(String, DownloadTapKind)> taps = [];

  @override
  void status(String id, DownloadStatus status, {int? httpStatus}) =>
      seen.add((id, status, httpStatus));

  @override
  void tapped(String id, DownloadTapKind kind) => taps.add((id, kind));

  List<DownloadStatus> get statuses => [for (final e in seen) e.$2];
}

DownloadRequest request({
  String id = 'a',
  DownloadLocation file = _location,
  int? bytes,
  String? sha256,
  DownloadNetwork network = DownloadNetwork.any,
  DownloadPriority priority = DownloadPriority.background,
}) => DownloadRequest(
  id: id,
  url: Uri.parse('https://files.example.com/$id'),
  file: file,
  bytes: bytes,
  sha256: sha256,
  network: network,
  priority: priority,
);

bd.DownloadTask taskOf(DownloadRequest r) => downloadTaskOf(r);

bd.TaskStatusUpdate statusOf(
  bd.Task task,
  bd.TaskStatus status, [
  bd.TaskException? exception,
]) => bd.TaskStatusUpdate(task, status, exception);

const _running = DownloadNotifications(running: 'Downloading');

BackgroundDownloaderBackend backend(
  FakeBackgroundTransport transport, {
  BackgroundPlatform platform = BackgroundPlatform.android,
  DownloadNotifications? notifications = _running,
  TransferFiles? files,
}) => BackgroundDownloaderBackend(
  transport: transport,
  platform: platform,
  notifications: notifications,
  files: files ?? FakeTransferFiles(),
  // A clock that never moves: every attempt of an id is created "in the same millisecond", the
  // worst case of a fast CI runner. Attempts must still be told apart.
  now: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
);

void main() {
  group('capabilities', () {
    test(
      'Android and iOS: background, pause, restart, unmetered, user-initiated',
      () {
        for (final p in [BackgroundPlatform.android, BackgroundPlatform.ios]) {
          final c = backend(
            FakeBackgroundTransport(),
            platform: p,
          ).capabilities;
          expect(c.background, isTrue, reason: '$p');
          expect(c.pause, isTrue);
          expect(c.resumeAcrossRestart, isTrue);
          expect(c.unmetered, isTrue);
          expect(c.userInitiated, isTrue);
        }
      },
    );

    test('notifications only when a running text is configured', () {
      final none = backend(FakeBackgroundTransport(), notifications: null);
      expect(none.capabilities.notifications, isFalse);
      final onlyDone = backend(
        FakeBackgroundTransport(),
        notifications: const DownloadNotifications(complete: 'Done'),
      );
      expect(onlyDone.capabilities.notifications, isFalse);
      expect(
        backend(FakeBackgroundTransport()).capabilities.notifications,
        isTrue,
      );
    });

    test(
      'configureNotifications changes them, and turns them off with null',
      () async {
        final b = backend(FakeBackgroundTransport(), notifications: null);
        await b.configureNotifications(_running);
        expect(b.capabilities.notifications, isTrue);
        await b.configureNotifications(null);
        expect(b.capabilities.notifications, isFalse);
      },
    );

    test('the desktop pauses and nothing else', () {
      final c = backend(
        FakeBackgroundTransport(),
        platform: BackgroundPlatform.desktop,
      ).capabilities;
      expect(c.pause, isTrue);
      expect(c.background, isFalse);
      expect(c.notifications, isFalse);
      expect(c.unmetered, isFalse);
      expect(c.userInitiated, isFalse);
      expect(c.resumeAcrossRestart, isFalse);
    });

    test('the web claims nothing', () {
      final c = backend(
        FakeBackgroundTransport(),
        platform: BackgroundPlatform.unsupported,
      ).capabilities;
      expect(c.pause || c.background || c.notifications, isFalse);
    });
  });

  group('open', () {
    test(
      'registers the callbacks before it asks the system for what it kept',
      () async {
        final t = FakeBackgroundTransport();
        await backend(t).open(Events());
        expect(t.calls, [
          'notifications:$_group',
          'register:$_group',
          'records:$_group',
          'track:$_group',
          'resumeFromBackground',
        ]);
      },
    );

    test(
      'what finished while the app was away reaches the engine, not the app',
      () async {
        final r = request();
        final t = FakeBackgroundTransport(
          undelivered: [
            statusOf(
              taskOf(r),
              bd.TaskStatus.failed,
              bd.TaskHttpException('x', 403),
            ),
          ],
        );
        final events = Events();
        await backend(t).open(events);
        expect(events.seen.single, (
          'a',
          const Failed(DownloadFailure.unauthorized),
          403,
        ));
        expect(t.leaked, isEmpty);
      },
    );

    test('only its own group is registered, tracked and configured', () async {
      final t = FakeBackgroundTransport();
      await backend(t).open(Events());
      expect(t.registered, {_group});
      expect(t.plans.keys, [_group]);
      expect(t.calls.where((c) => c.startsWith('track:')), ['track:$_group']);
    });

    test('the web never touches the plugin', () async {
      final t = FakeBackgroundTransport();
      final b = backend(t, platform: BackgroundPlatform.unsupported);
      final events = Events();
      await b.open(events);
      expect(await b.enqueue(request()), isTrue);
      expect(events.statuses, [const Failed(DownloadFailure.unsupported)]);
      await b.cancel('a');
      await b.cancelAll();
      await b.close();
      expect(t.calls, isEmpty);
    });

    test('the plugin\'s records are replayed; a task the system lost is left to the engine', () async {
      final done = request(id: 'done');
      final failed = request(id: 'failed');
      final paused = request(id: 'paused');
      final lost = request(id: 'lost');
      final running = request(id: 'running');
      final t = FakeBackgroundTransport(
        records: [
          bd.TaskRecord(taskOf(done), bd.TaskStatus.complete, 1, 10),
          bd.TaskRecord(
            taskOf(failed),
            bd.TaskStatus.failed,
            bd.progressFailed,
            -1,
            bd.TaskConnectionException('x'),
          ),
          bd.TaskRecord(taskOf(paused), bd.TaskStatus.paused, 0.5, 100),
          bd.TaskRecord(taskOf(lost), bd.TaskStatus.running, 0.5, 100),
          bd.TaskRecord(taskOf(running), bd.TaskStatus.running, 0.25, 100),
        ],
        active: {'running'},
      );
      final files = FakeTransferFiles()
        ..putBytes('/fake/support/maps/a.bin', List.filled(10, 1));
      final events = Events();
      await backend(t, files: files).open(events);
      final byId = {for (final e in events.seen) e.$1: e.$2};
      expect(byId['done'], const Complete(_location, 10));
      expect(byId['failed'], const Failed(DownloadFailure.network));
      expect(byId['paused'], const Paused(50, 100));
      expect(byId['running'], const Running(25, 100));
      expect(byId.containsKey('lost'), isFalse);
      // Nothing was enqueued again: the engine retries with a fresh grant.
      expect(t.enqueued, isEmpty);
    });

    test('a record of another group is not this backend\'s', () async {
      final other = bd.DownloadTask(
        taskId: 'x',
        url: 'https://a.example/x',
        group: 'the-app',
      );
      final t = FakeBackgroundTransport(
        records: [bd.TaskRecord(other, bd.TaskStatus.complete, 1, 1)],
      );
      final events = Events();
      await backend(t).open(events);
      expect(events.seen, isEmpty);
    });
  });

  group('enqueue', () {
    late FakeBackgroundTransport t;
    late Events events;

    Future<BackgroundDownloaderBackend> open({
      DownloadNotifications? notifications = _running,
      BackgroundPlatform platform = BackgroundPlatform.android,
    }) async {
      t = FakeBackgroundTransport();
      events = Events();
      final b = backend(t, notifications: notifications, platform: platform);
      await b.open(events);
      return b;
    }

    test(
      'hands the plugin the mapped task, with the attempt\'s headers',
      () async {
        final b = await open();
        expect(
          await b.enqueue(request(), authorization: {'Authorization': 'grant'}),
          isTrue,
        );
        final task = t.enqueued.single;
        expect(task.taskId, 'a');
        expect(task.group, _group);
        expect(task.headers, {'Authorization': 'grant'});
      },
    );

    test('the plugin refusing the task is a false', () async {
      final b = await open();
      t.accepts = false;
      expect(await b.enqueue(request()), isFalse);
    });

    test(
      'an invalid request ends invalidRequest and is not enqueued',
      () async {
        final b = await open();
        final bad = request(
          file: const DownloadLocation(DownloadBase.support, '../x'),
        );
        expect(await b.enqueue(bad), isTrue);
        expect(events.statuses, [const Failed(DownloadFailure.invalidRequest)]);
        expect(t.enqueued, isEmpty);
      },
    );

    test(
      'userInitiated without a notification is refused, nothing enqueued',
      () async {
        final b = await open(notifications: null);
        expect(
          await b.enqueue(request(priority: DownloadPriority.userInitiated)),
          isTrue,
        );
        expect(events.statuses, [
          const Failed(DownloadFailure.notificationsRequired),
        ]);
        expect(t.enqueued, isEmpty);
      },
    );

    test('userInitiated with a notification is priority 0', () async {
      final b = await open();
      await b.enqueue(request(priority: DownloadPriority.userInitiated));
      expect(t.enqueued.single.priority, 0);
      expect(events.seen, isEmpty);
    });

    test('a background request needs no notification', () async {
      final b = await open(notifications: null);
      await b.enqueue(request());
      expect(t.enqueued.single.priority, 5);
    });

    test('the desktop refuses unmetered', () async {
      final b = await open(platform: BackgroundPlatform.desktop);
      expect(
        await b.enqueue(request(network: DownloadNetwork.unmetered)),
        isFalse,
      );
      expect(t.enqueued, isEmpty);
    });

    test('two downloads do not write one file', () async {
      final b = await open();
      await b.enqueue(request());
      await b.enqueue(request(id: 'b'));
      expect(events.statuses, [const Failed(DownloadFailure.invalidRequest)]);
      expect(t.enqueued, hasLength(1));
    });

    test('before open it answers false', () async {
      final b = backend(FakeBackgroundTransport());
      expect(await b.enqueue(request()), isFalse);
    });
  });

  group('updates', () {
    late FakeBackgroundTransport t;
    late Events events;
    late BackgroundDownloaderBackend b;
    late FakeTransferFiles files;

    setUp(() async {
      t = FakeBackgroundTransport();
      events = Events();
      files = FakeTransferFiles();
      b = backend(t, files: files);
      await b.open(events);
    });

    test('status and progress become the engine\'s statuses', () async {
      final r = request();
      await b.enqueue(r);
      final task = t.enqueued.single;
      t.emitStatus(statusOf(task, bd.TaskStatus.enqueued));
      t.emitStatus(statusOf(task, bd.TaskStatus.running));
      t.emitProgress(bd.TaskProgressUpdate(task, 0.5, 200));
      t.emitStatus(statusOf(task, bd.TaskStatus.paused));
      expect(events.statuses, [
        const Queued(),
        const Running(0),
        const Running(100, 200),
        const Paused(100, 200),
      ]);
    });

    test('the plugin\'s end markers are not reported as progress', () async {
      await b.enqueue(request());
      final task = t.enqueued.single;
      t.emitProgress(bd.TaskProgressUpdate(task, bd.progressPaused));
      t.emitProgress(bd.TaskProgressUpdate(task, bd.progressFailed));
      expect(events.seen, isEmpty);
    });

    test(
      'a failure carries its HTTP status, and a 401 is unauthorized',
      () async {
        await b.enqueue(request());
        final task = t.enqueued.single;
        t.emitStatus(
          statusOf(
            task,
            bd.TaskStatus.failed,
            bd.TaskHttpException('private text', 401),
          ),
        );
        expect(events.seen.single, (
          'a',
          const Failed(DownloadFailure.unauthorized),
          401,
        ));
      },
    );

    test('progress after the end is dropped', () async {
      await b.enqueue(request());
      final task = t.enqueued.single;
      t.emitStatus(
        statusOf(task, bd.TaskStatus.failed, bd.TaskConnectionException('x')),
      );
      t.emitProgress(bd.TaskProgressUpdate(task, 0.5, 200));
      expect(events.statuses, [const Failed(DownloadFailure.network)]);
    });

    test('a notification tap reaches the engine as a body tap', () async {
      await b.enqueue(request());
      t.tap(t.enqueued.single, bd.NotificationType.complete);
      expect(events.taps, [('a', DownloadTapKind.body)]);
    });

    test(
      'after close nothing is reported and the group has no callbacks',
      () async {
        await b.enqueue(request());
        final task = t.enqueued.single;
        await b.close();
        expect(t.registered, isEmpty);
        t.emitStatus(statusOf(task, bd.TaskStatus.running));
        expect(events.seen, isEmpty);
        // What the plugin does with it then is the app's stream's business, not ours.
        expect(t.leaked, hasLength(1));
      },
    );

    group('a finished file', () {
      const path = '/fake/support/maps/a.bin';

      Future<void> finish(DownloadRequest r) async {
        await b.enqueue(r);
        t.emitStatus(statusOf(t.enqueued.last, bd.TaskStatus.complete));
        await pumpEventQueue();
      }

      test('with nothing to check is Complete with the size on disk', () async {
        files.putBytes(path, List.filled(12, 3));
        await finish(request());
        expect(events.statuses, [const Complete(_location, 12)]);
      });

      test('a size that differs is sizeMismatch, after Verifying', () async {
        files.putBytes(path, List.filled(12, 3));
        await finish(request(bytes: 13));
        expect(events.statuses, [
          const Verifying(),
          const Failed(DownloadFailure.sizeMismatch),
        ]);
      });

      test('a digest that differs is hashMismatch', () async {
        files.putBytes(path, List.filled(12, 3));
        await finish(request(bytes: 12, sha256: '0' * 64));
        expect(events.statuses, [
          const Verifying(),
          const Failed(DownloadFailure.hashMismatch),
        ]);
      });

      test('the right size and digest is Complete', () async {
        files.putBytes(path, List.filled(12, 3));
        final digest = await files.sha256(path);
        await finish(request(bytes: 12, sha256: digest));
        expect(events.statuses, [
          const Verifying(),
          const Complete(_location, 12),
        ]);
      });

      test('a file that is not there is a storage failure', () async {
        await finish(request());
        expect(events.statuses, [const Failed(DownloadFailure.storage)]);
      });

      test('a check that finishes after a cancel reports nothing', () async {
        files.putBytes(path, List.filled(12, 3));
        await b.enqueue(request());
        t.emitStatus(statusOf(t.enqueued.single, bd.TaskStatus.complete));
        await b.cancel('a');
        await pumpEventQueue();
        expect(events.seen, isEmpty);
      });

      test(
        'what finished while the app was away is checked before open returns',
        () async {
          files.putBytes(path, List.filled(12, 3));
          final r = request(bytes: 99);
          final late = FakeBackgroundTransport(
            undelivered: [statusOf(taskOf(r), bd.TaskStatus.complete)],
          );
          final lateEvents = Events();
          await backend(late, files: files).open(lateEvents);
          expect(lateEvents.statuses, [
            const Verifying(),
            const Failed(DownloadFailure.sizeMismatch),
          ]);
        },
      );
    });
  });

  group('control', () {
    late FakeBackgroundTransport t;
    late BackgroundDownloaderBackend b;

    setUp(() async {
      t = FakeBackgroundTransport();
      b = backend(t);
      await b.open(Events());
      await b.enqueue(request());
    });

    test('pause hands the plugin the task', () async {
      expect(await b.pause('a'), isTrue);
      expect(t.paused.single.taskId, 'a');
      expect(await b.pause('nope'), isFalse);
    });

    test('pause is the plugin\'s answer', () async {
      t.pauseAccepts = false;
      expect(await b.pause('a'), isFalse);
    });

    test('a task the app forgot is found again in the plugin', () async {
      final fresh = backend(t);
      await fresh.open(Events());
      expect(await fresh.pause('a'), isTrue);
    });

    test('resume sends the headers the task has', () async {
      expect(await b.resume('a'), isTrue);
      expect(t.resumed.single.headers, isEmpty);
    });

    test(
      'resume with a fresh grant replaces the header (UNCHECKED on a device)',
      () async {
        expect(
          await b.resume('a', authorization: {'Authorization': 'new'}),
          isTrue,
        );
        expect(t.resumed.single.headers, {'Authorization': 'new'});
      },
    );

    test('resume with no resume data is the plugin\'s false', () async {
      t.resumeAccepts = false;
      expect(await b.resume('a'), isFalse);
    });

    test('pause and resume of an unknown id are false', () async {
      expect(await b.pause('zzz'), isFalse);
      expect(await b.resume('zzz'), isFalse);
    });

    test('cancel cancels the id', () async {
      await b.cancel('a');
      expect(t.cancelled, ['a']);
    });

    test('cancelAll cancels this group only', () async {
      await b.cancelAll();
      expect(t.cancelledGroups, [_group]);
    });

    test('resolve asks the plugin for the path of a location', () async {
      expect(await b.resolve(_location), '/fake/support/maps/a.bin');
    });

    test('the web cannot pause, resume or resolve', () async {
      final web = backend(
        FakeBackgroundTransport(),
        platform: BackgroundPlatform.unsupported,
      );
      expect(await web.pause('a'), isFalse);
      expect(await web.resume('a'), isFalse);
      await expectLater(
        web.resolve(_location),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('with the engine', () {
    late RecordingTelemetry rec;

    setUp(() {
      rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
      addTearDown(() => FespalierTelemetry.install(null));
    });

    test('a download runs to the end and its span says background', () async {
      final t = FakeBackgroundTransport();
      final files = FakeTransferFiles()
        ..putBytes('/fake/support/maps/a.bin', List.filled(8, 1));
      final engine = Downloads(
        backend: backend(t, files: files),
        store: MemoryDownloadStore(),
      );
      await engine.open();
      await engine.start(request(bytes: 8));
      final task = t.enqueued.single;
      t.emitStatus(statusOf(task, bd.TaskStatus.running));
      t.emitProgress(bd.TaskProgressUpdate(task, 0.5, 8));
      expect(engine.statusOf('a'), const Running(4, 8));
      t.emitStatus(statusOf(task, bd.TaskStatus.complete));
      await pumpEventQueue();
      expect(engine.statusOf('a'), const Complete(_location, 8));
      expect(await engine.pathOf('a'), '/fake/support/maps/a.bin');
      final log = rec.log.join('\n');
      expect(log, contains('start custom fespalier.download.transfer'));
      expect(log, contains('fespalier.download.background=true'));
      // Never the url, the id, the path or the name.
      expect(log, isNot(contains('files.example.com')));
      expect(log, isNot(contains('maps/a.bin')));
    });

    test(
      'userInitiated without notifications ends Failed(notificationsRequired)',
      () async {
        final t = FakeBackgroundTransport();
        final engine = Downloads(
          backend: backend(t, notifications: null),
          store: MemoryDownloadStore(),
        );
        await engine.open();
        await engine.start(request(priority: DownloadPriority.userInitiated));
        expect(
          engine.statusOf('a'),
          const Failed(DownloadFailure.notificationsRequired),
        );
        expect(t.enqueued, isEmpty);
      },
    );

    test('a 401 ends unauthorized through the engine', () async {
      final t = FakeBackgroundTransport();
      final engine = Downloads(
        backend: backend(t),
        store: MemoryDownloadStore(),
      );
      await engine.open();
      await engine.start(request());
      t.emitStatus(
        statusOf(
          t.enqueued.single,
          bd.TaskStatus.failed,
          bd.TaskHttpException('x', 403),
        ),
      );
      expect(engine.statusOf('a'), const Failed(DownloadFailure.unauthorized));
    });

    test('a renewed grant: the 401 is answered with a new attempt, and the old one\'s cancel does not end it', () async {
      final t = FakeBackgroundTransport();
      var asked = 0;
      final engine = Downloads(
        backend: backend(t),
        store: MemoryDownloadStore(),
        grantor: (r, {required bool renewal}) {
          asked++;
          return DownloadGrant(
            url: Uri.parse('https://files.example.com/grant-$asked'),
            headers: {'Authorization': 'grant-$asked'},
          );
        },
      );
      await engine.open();
      await engine.start(request());
      final first = t.enqueued.single;
      expect(first.url, endsWith('/grant-1'));
      expect(first.headers, {'Authorization': 'grant-1'});
      t.emitStatus(
        statusOf(first, bd.TaskStatus.failed, bd.TaskHttpException('x', 401)),
      );
      await pumpEventQueue();
      expect(t.cancelled, ['a']);
      expect(t.enqueued, hasLength(2));
      final second = t.enqueued.last;
      expect(second.url, endsWith('/grant-2'));
      expect(second.headers, {'Authorization': 'grant-2'});
      // The plugin\'s answer to our cancel of the first attempt arrives late.
      t.emitStatus(statusOf(first, bd.TaskStatus.canceled));
      t.emitProgress(bd.TaskProgressUpdate(first, 0.5, 10));
      await pumpEventQueue();
      expect(engine.statusOf('a'), isNot(isA<Cancelled>()));
      expect(engine.statusOf('a'), const Queued());
      t.emitStatus(statusOf(second, bd.TaskStatus.running));
      expect(engine.statusOf('a'), const Running(0));
    });

    test('attempts of one id get strictly increasing creation times', () async {
      final t = FakeBackgroundTransport();
      final engine = Downloads(
        backend: backend(t),
        store: MemoryDownloadStore(),
      );
      await engine.open();
      await engine.start(request());
      t.emitStatus(
        statusOf(
          t.enqueued.single,
          bd.TaskStatus.failed,
          bd.TaskConnectionException('x'),
        ),
      );
      await engine.retry('a');
      expect(
        t.enqueued.last.creationTime.isAfter(t.enqueued.first.creationTime),
        isTrue,
      );
    });

    test(
      'retry: the old attempt\'s late canceled does not cancel the new one',
      () async {
        final t = FakeBackgroundTransport();
        final engine = Downloads(
          backend: backend(t),
          store: MemoryDownloadStore(),
        );
        await engine.open();
        await engine.start(request());
        final first = t.enqueued.single;
        t.emitStatus(
          statusOf(
            first,
            bd.TaskStatus.failed,
            bd.TaskConnectionException('x'),
          ),
        );
        await engine.retry('a');
        expect(t.enqueued, hasLength(2));
        t.emitStatus(statusOf(first, bd.TaskStatus.canceled));
        await pumpEventQueue();
        expect(engine.statusOf('a'), const Queued());
        // A cancel of the new attempt (the person, from a notification) still counts.
        t.emitStatus(statusOf(t.enqueued.last, bd.TaskStatus.canceled));
        await pumpEventQueue();
        expect(engine.statusOf('a'), const Cancelled());
      },
    );

    test('after a restart the plugin\'s record settles the registry', () async {
      final r = request(bytes: 8);
      final store = MemoryDownloadStore({'a': StoredDownload(r)});
      final files = FakeTransferFiles()
        ..putBytes('/fake/support/maps/a.bin', List.filled(8, 1));
      final t = FakeBackgroundTransport(
        records: [bd.TaskRecord(taskOf(r), bd.TaskStatus.complete, 1, 8)],
      );
      final engine = Downloads(
        backend: backend(t, files: files),
        store: store,
      );
      await engine.open();
      expect(engine.statusOf('a'), const Complete(_location, 8));
    });

    test('after a restart a task the system lost is killed, then retried with a fresh grant', () async {
      final r = request();
      final store = MemoryDownloadStore({'a': StoredDownload(r)});
      final t = FakeBackgroundTransport(
        records: [bd.TaskRecord(taskOf(r), bd.TaskStatus.running, 0.3, 10)],
      );
      final engine = Downloads(backend: backend(t), store: store);
      await engine.open();
      expect(engine.statusOf('a'), const Failed(DownloadFailure.killed));
      expect(t.enqueued, isEmpty);
      await engine.retry('a');
      expect(t.enqueued, hasLength(1));
    });
  });
}
