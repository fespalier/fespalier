// The upload backend's logic, driven through FakeUploadTransport: no plugin, no device. What an
// operating system decides is not here (docs/downloads.md, "Uploads", lists it as unchecked).
import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:fespalier_download_background/fespalier_download_background.dart';
import 'package:fespalier_download_background/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _file = DownloadLocation(DownloadBase.documents, 'outbox/a.jpg');

final class Events implements UploadEvents {
  final List<(String, DownloadStatus, int?)> seen = [];

  @override
  void status(String id, DownloadStatus status, {int? httpStatus}) =>
      seen.add((id, status, httpStatus));

  List<DownloadStatus> get statuses => [for (final e in seen) e.$2];
}

UploadRequest request({
  String id = 'a',
  bool safe = false,
  DownloadNetwork network = DownloadNetwork.any,
  DownloadPriority priority = DownloadPriority.background,
}) => UploadRequest(
  id: id,
  url: Uri.parse('https://api.example.com/$id'),
  file: _file,
  headers: safe ? const {'Idempotency-Key': 'k'} : const {},
  network: network,
  priority: priority,
);

const _running = DownloadNotifications(running: 'Uploading');

BackgroundUploaderBackend backend(
  FakeUploadTransport transport, {
  BackgroundPlatform platform = BackgroundPlatform.android,
  DownloadNotifications? notifications = _running,
  FakeTransferFiles? files,
}) => BackgroundUploaderBackend(
  transport: transport,
  platform: platform,
  notifications: notifications,
  files: files ?? FakeTransferFiles(),
  // A clock that never moves: every attempt of an id is created "in the same millisecond".
  now: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
);

bd.TaskStatusUpdate update(
  bd.Task task,
  bd.TaskStatus status, [
  bd.TaskException? exception,
]) => bd.TaskStatusUpdate(task, status, exception);

void main() {
  group('capabilities', () {
    test('mobile: background, user-initiated, unmetered, never pause', () {
      for (final p in [BackgroundPlatform.android, BackgroundPlatform.ios]) {
        final c = backend(FakeUploadTransport(), platform: p).capabilities;
        expect(c.background, isTrue);
        expect(c.userInitiated, isTrue);
        expect(c.unmetered, isTrue);
        expect(c.notifications, isTrue);
        expect(c.pause, isFalse);
        expect(c.resumeAcrossRestart, isFalse);
      }
    });

    test('no notification text, no notifications', () {
      expect(
        backend(
          FakeUploadTransport(),
          notifications: null,
        ).capabilities.notifications,
        isFalse,
      );
    });

    test('desktop and web claim nothing', () {
      for (final p in [
        BackgroundPlatform.desktop,
        BackgroundPlatform.unsupported,
      ]) {
        final c = backend(FakeUploadTransport(), platform: p).capabilities;
        expect(c.background || c.userInitiated || c.unmetered, isFalse);
        expect(c.pause, isFalse);
      }
    });
  });

  group('open', () {
    test('callbacks for its own group, before resumeFromBackground', () async {
      final t = FakeUploadTransport();
      await backend(t).open(Events());
      expect(t.calls.indexOf('register:$backgroundUploadGroup'), isNonNegative);
      expect(
        t.calls.indexOf('register:$backgroundUploadGroup'),
        lessThan(t.calls.indexOf('resumeFromBackground')),
      );
      expect(t.registered, {backgroundUploadGroup});
    });

    test(
      'what finished while the app was away is delivered to this group',
      () async {
        final task = uploadTaskOf(request());
        final t = FakeUploadTransport(
          undelivered: [update(task, bd.TaskStatus.complete)],
        );
        final events = Events();
        await backend(t).open(events);
        expect(t.leaked, isEmpty);
        expect(events.statuses.single, isA<Complete>());
      },
    );

    test('the web never touches the plugin', () async {
      final t = FakeUploadTransport();
      final b = backend(t, platform: BackgroundPlatform.unsupported);
      final events = Events();
      await b.open(events);
      expect(t.calls, isEmpty);
      expect(await b.enqueue(request()), isTrue);
      expect(events.statuses, [const Failed(DownloadFailure.unsupported)]);
      expect(t.enqueued, isEmpty);
    });

    test('a record the plugin kept as running but the OS no longer has is not reported', () async {
      final task = uploadTaskOf(request());
      final t = FakeUploadTransport(
        records: [bd.TaskRecord(task, bd.TaskStatus.running, 0.5, 100)],
      );
      final events = Events();
      await backend(t).open(events);
      expect(events.seen, isEmpty, reason: 'the engine ends it Failed(killed)');
      expect(t.enqueued, isEmpty, reason: 'and nothing is sent again');
    });

    test('a record that ended is replayed', () async {
      final task = uploadTaskOf(request());
      final t = FakeUploadTransport(
        records: [
          bd.TaskRecord(
            task,
            bd.TaskStatus.failed,
            -1,
            -1,
            bd.TaskConnectionException('x'),
          ),
        ],
      );
      final events = Events();
      await backend(t).open(events);
      expect(events.statuses.single, const Failed(DownloadFailure.network));
    });

    test(
      'a download task of the app in the same records is not ours',
      () async {
        final other = bd.DownloadTask(
          url: 'https://x.example.com/',
          group: backgroundUploadGroup,
        );
        final t = FakeUploadTransport(
          records: [bd.TaskRecord(other, bd.TaskStatus.complete, 1, 1)],
        );
        final events = Events();
        await backend(t).open(events);
        expect(events.seen, isEmpty);
      },
    );
  });

  group('enqueue', () {
    test(
      'hands the plugin one UploadTask with the retries of its replay safety',
      () async {
        final t = FakeUploadTransport();
        final b = backend(t);
        await b.open(Events());
        expect(await b.enqueue(request(id: 'plain')), isTrue);
        expect(await b.enqueue(request(id: 'safe', safe: true)), isTrue);
        expect(t.enqueued[0].retries, 0);
        expect(t.enqueued[1].retries, defaultUploadOptions.retries);
        expect(t.enqueued.every((e) => e.allowPause == false), isTrue);
      },
    );

    test('the authorization of the attempt is in the task headers', () async {
      final t = FakeUploadTransport();
      final b = backend(t);
      await b.open(Events());
      await b.enqueue(request(), authorization: {'X-Grant': 'g'});
      expect(t.enqueued.single.headers['X-Grant'], 'g');
    });

    test('an invalid request, an unmet user-initiated need and a refused network are reported or refused', () async {
      final t = FakeUploadTransport();
      final b = backend(t, notifications: null);
      final events = Events();
      await b.open(events);
      await b.enqueue(
        UploadRequest(
          id: 'a',
          url: Uri.parse('https://x.example.com/'),
          file: const DownloadLocation(DownloadBase.support, '/abs'),
        ),
      );
      await b.enqueue(request(priority: DownloadPriority.userInitiated));
      expect(events.statuses, [
        const Failed(DownloadFailure.invalidRequest),
        const Failed(DownloadFailure.notificationsRequired),
      ]);
      expect(t.enqueued, isEmpty);
      final desktop = backend(
        FakeUploadTransport(),
        platform: BackgroundPlatform.desktop,
      );
      await desktop.open(Events());
      expect(
        await desktop.enqueue(request(network: DownloadNetwork.unmetered)),
        isFalse,
      );
    });

    test('a plugin that refuses answers false', () async {
      final t = FakeUploadTransport(accepts: false);
      final b = backend(t);
      await b.open(Events());
      expect(await b.enqueue(request()), isFalse);
    });
  });

  group('updates', () {
    test('progress and the end of an upload', () async {
      final t = FakeUploadTransport();
      final b = backend(t);
      final events = Events();
      await b.open(events);
      await b.enqueue(request());
      final task = t.enqueued.single;
      t.emitProgress(bd.TaskProgressUpdate(task, 0.5, 1000));
      t.emitStatus(update(task, bd.TaskStatus.running));
      t.emitStatus(update(task, bd.TaskStatus.complete));
      await pumpEventQueue();
      expect(events.statuses, [
        const Running(500, 1000),
        const Running(500, 1000),
        const Complete(_file, 0),
      ]);
    });

    test('Complete carries the size of the file that was sent, when it can be read', () async {
      final files = FakeTransferFiles()
        ..putBytes('/fake/documents/outbox/a.jpg', List.filled(7, 1));
      final t = FakeUploadTransport();
      final b = backend(t, files: files);
      final events = Events();
      await b.open(events);
      await b.enqueue(request());
      t.emitStatus(update(t.enqueued.single, bd.TaskStatus.complete));
      await pumpEventQueue();
      expect(events.statuses.single, const Complete(_file, 7));
      expect(
        await files.length('/fake/documents/outbox/a.jpg'),
        7,
        reason: 'untouched',
      );
    });

    test('a refusal carries its HTTP status', () async {
      final t = FakeUploadTransport();
      final b = backend(t);
      final events = Events();
      await b.open(events);
      await b.enqueue(request());
      t.emitStatus(
        update(
          t.enqueued.single,
          bd.TaskStatus.failed,
          bd.TaskHttpException('x', 403),
        ),
      );
      expect(events.seen.single.$2, const Failed(DownloadFailure.unauthorized));
      expect(events.seen.single.$3, 403);
    });

    test('the update of a cancelled attempt does not end its successor, however fast it follows', () async {
      final t = FakeUploadTransport();
      final b = backend(t);
      final events = Events();
      await b.open(events);
      await b.enqueue(request(safe: true));
      final first = t.enqueued.single;
      await b.cancel('a');
      await b.enqueue(request(safe: true));
      final second = t.enqueued.last;
      expect(second.creationTime, isNot(first.creationTime));
      t.emitStatus(update(first, bd.TaskStatus.canceled));
      t.emitStatus(update(second, bd.TaskStatus.running));
      expect(events.statuses, [const Running(0)]);
    });

    test('a late progress of an ended upload is not reported', () async {
      final t = FakeUploadTransport();
      final b = backend(t);
      final events = Events();
      await b.open(events);
      await b.enqueue(request());
      final task = t.enqueued.single;
      t.emitStatus(
        update(task, bd.TaskStatus.failed, bd.TaskConnectionException('x')),
      );
      t.emitProgress(bd.TaskProgressUpdate(task, 0.9, 10));
      expect(events.statuses, [const Failed(DownloadFailure.network)]);
    });
  });

  group('cancel, close and notifications', () {
    test(
      'cancel and cancelAll forget the plugin records of the group',
      () async {
        final t = FakeUploadTransport();
        final b = backend(t);
        await b.open(Events());
        await b.enqueue(request());
        await b.cancel('a');
        await b.cancelAll();
        expect(t.cancelled, ['a']);
        expect(t.calls, contains('cancelAll:$backgroundUploadGroup'));
      },
    );

    test('close unregisters its group only', () async {
      final t = FakeUploadTransport();
      final b = backend(t);
      await b.open(Events());
      await b.close();
      expect(t.registered, isEmpty);
      expect(t.calls, contains('unregister:$backgroundUploadGroup'));
    });

    test(
      'notification texts become the group\'s plan, and null turns them off',
      () async {
        final t = FakeUploadTransport();
        final b = backend(t);
        await b.open(Events());
        expect(t.plans[backgroundUploadGroup]!.hasRunning, isTrue);
        await b.configureNotifications(null);
        expect(t.plans[backgroundUploadGroup]!.isEmpty, isTrue);
        expect(b.capabilities.notifications, isFalse);
      },
    );
  });
}
