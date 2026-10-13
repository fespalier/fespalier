// The pure layer: a request as a plugin task, a plugin update as a status. No plugin call, no
// platform channel.
import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download_background/fespalier_download_background.dart';
import 'package:flutter_test/flutter_test.dart';

final _url = Uri.parse('https://files.example.com/a.bin');

DownloadRequest request({
  String id = 'a',
  DownloadLocation file = const DownloadLocation(
    DownloadBase.support,
    'maps/city/a.pmtiles',
  ),
  Map<String, String> headers = const {},
  int? bytes,
  String? sha256,
  DownloadNetwork network = DownloadNetwork.any,
  DownloadPriority priority = DownloadPriority.background,
  String? displayName,
}) => DownloadRequest(
  id: id,
  url: _url,
  file: file,
  headers: headers,
  bytes: bytes,
  sha256: sha256,
  network: network,
  priority: priority,
  displayName: displayName,
);

bd.DownloadTask task({
  String directory = 'maps',
  String filename = 'a.bin',
  bd.BaseDirectory base = bd.BaseDirectory.applicationSupport,
  String metaData = '',
}) => bd.DownloadTask(
  taskId: 'a',
  url: _url.toString(),
  directory: directory,
  filename: filename,
  baseDirectory: base,
  group: backgroundDownloadGroup,
  metaData: metaData,
);

void main() {
  group('a request as a plugin task', () {
    test('the id, the group, the url and the updates', () {
      final t = downloadTaskOf(request());
      expect(t.taskId, 'a');
      expect(t.group, 'fespalier.download');
      expect(t.url, _url.toString());
      expect(t.updates, bd.Updates.statusAndProgress);
      expect(t.httpRequestMethod, 'GET');
    });

    test('the file is a base, a sub-folder and a name, never absolute', () {
      final t = downloadTaskOf(request());
      expect(t.baseDirectory, bd.BaseDirectory.applicationSupport);
      expect(t.directory, 'maps/city');
      expect(t.filename, 'a.pmtiles');
      final flat = downloadTaskOf(
        request(file: const DownloadLocation(DownloadBase.cache, 'a.bin')),
      );
      expect(flat.baseDirectory, bd.BaseDirectory.temporary);
      expect(flat.directory, '');
      expect(flat.filename, 'a.bin');
      final docs = downloadTaskOf(
        request(file: const DownloadLocation(DownloadBase.documents, 'x/y')),
      );
      expect(docs.baseDirectory, bd.BaseDirectory.applicationDocuments);
    });

    test('a task points back to the request\'s location', () {
      for (final location in const [
        DownloadLocation(DownloadBase.support, 'maps/city/a.pmtiles'),
        DownloadLocation(DownloadBase.cache, 'a.bin'),
        DownloadLocation(DownloadBase.documents, 'a/b/c/d.pdf'),
      ]) {
        expect(locationOf(downloadTaskOf(request(file: location))), location);
      }
    });

    test('a task outside the three bases has no location', () {
      expect(
        locationOf(task(base: bd.BaseDirectory.applicationLibrary)),
        isNull,
      );
      expect(locationOf(task(base: bd.BaseDirectory.root)), isNull);
    });

    test('userInitiated is priority 0, background is the default 5', () {
      expect(
        downloadTaskOf(request(priority: DownloadPriority.userInitiated))
            .priority,
        0,
      );
      expect(downloadTaskOf(request()).priority, 5);
      expect(userInitiatedPriority, 0);
      expect(backgroundPriority, 5);
    });

    test('every task allows pause, which is how a long download survives', () {
      expect(downloadTaskOf(request()).allowPause, isTrue);
      expect(
        downloadTaskOf(request(priority: DownloadPriority.userInitiated))
            .allowPause,
        isTrue,
      );
    });

    test('unmetered is requiresWiFi', () {
      expect(downloadTaskOf(request()).requiresWiFi, isFalse);
      expect(
        downloadTaskOf(request(network: DownloadNetwork.unmetered))
            .requiresWiFi,
        isTrue,
      );
    });

    test('retries come from the options, 0 through 10', () {
      expect(downloadTaskOf(request()).retries, 3);
      expect(
        downloadTaskOf(
          request(),
          options: const BackgroundOptions(retries: 0),
        ).retries,
        0,
      );
      expect(
        () => BackgroundOptions(retries: 11),
        throwsA(isA<AssertionError>()),
      );
    });

    test('the group is the options\'', () {
      final t = downloadTaskOf(
        request(),
        options: const BackgroundOptions(group: 'mine'),
      );
      expect(t.group, 'mine');
    });

    test('headers are the request\'s, then the attempt\'s over them', () {
      final t = downloadTaskOf(
        request(headers: {'X-One': '1', 'X-Two': 'old'}),
        authorization: {'X-Two': 'new', 'Authorization': 'grant'},
      );
      expect(t.headers, {
        'X-One': '1',
        'X-Two': 'new',
        'Authorization': 'grant',
      });
    });

    test('the display name is the task\'s, empty when there is none', () {
      expect(
        downloadTaskOf(request(displayName: 'City map')).displayName,
        'City map',
      );
      expect(downloadTaskOf(request()).displayName, '');
    });

    test(
      'the size and the digest travel in the metadata, and nothing else does',
      () {
        final digest = 'AB' * 32;
        final t = downloadTaskOf(
          request(
            bytes: 99,
            sha256: digest,
            headers: {'Authorization': 'secret'},
            displayName: 'Private name',
          ),
        );
        final expectation = TaskExpectation.decode(t.metaData);
        expect(expectation.bytes, 99);
        expect(expectation.sha256, digest.toLowerCase());
        expect(t.metaData, isNot(contains('secret')));
        expect(t.metaData, isNot(contains('Private')));
        expect(t.metaData, isNot(contains('files.example.com')));
        expect(downloadTaskOf(request()).metaData, '');
      },
    );

    test('a foreground service is never asked for', () {
      // The task has no field for it; the plugin's global switch is never set (the
      // no_timers_test greps lib/ for `Config.`). Nothing to read off the task.
      final t = downloadTaskOf(
        request(priority: DownloadPriority.userInitiated),
      );
      expect(t.transferHints, isNull);
      expect(t.notificationConfig, isNull);
    });

    test('the path probe names a location and is never a real request', () {
      final probe = pathProbeOf(
        const DownloadLocation(DownloadBase.support, 'a/b.bin'),
      );
      expect(probe.directory, 'a');
      expect(probe.filename, 'b.bin');
      expect(probe.baseDirectory, bd.BaseDirectory.applicationSupport);
    });
  });

  group('the expectation in the metadata', () {
    test('round-trips, and an empty one is the empty string', () {
      const e = TaskExpectation(bytes: 5, sha256: 'a');
      expect(TaskExpectation.none.encode(), '');
      expect(TaskExpectation.none.isEmpty, isTrue);
      expect(TaskExpectation(bytes: 5).encode(), '{"b":5}');
      expect(
        TaskExpectation.decode(const TaskExpectation(bytes: 5).encode()).bytes,
        5,
      );
      expect(e.isEmpty, isFalse);
    });

    test('anything that is not one is none, and never throws', () {
      for (final text in const [
        '',
        'hello',
        '[1,2]',
        '{"b":-1}',
        '{"b":"x","h":3}',
        '{"h":"short"}',
        '{',
      ]) {
        expect(TaskExpectation.decode(text).isEmpty, isTrue, reason: text);
      }
    });
  });

  group('a failure', () {
    test('401 and 403 are unauthorized, any other HTTP error is rejected', () {
      expect(failureOf(bd.TaskHttpException('x', 401)), (
        DownloadFailure.unauthorized,
        401,
      ));
      expect(failureOf(bd.TaskHttpException('x', 403)), (
        DownloadFailure.unauthorized,
        403,
      ));
      expect(failureOf(bd.TaskHttpException('x', 500)), (
        DownloadFailure.rejected,
        500,
      ));
      expect(failureOf(bd.TaskHttpException('x', 410)), (
        DownloadFailure.rejected,
        410,
      ));
    });

    test(
      'the response status code is read when there is no HTTP exception',
      () {
        expect(failureOf(null, responseStatusCode: 401), (
          DownloadFailure.unauthorized,
          401,
        ));
        expect(failureOf(null, responseStatusCode: 200), (
          DownloadFailure.other,
          null,
        ));
      },
    );

    test('the exception\'s type decides the rest, never its text', () {
      expect(failureOf(bd.TaskConnectionException('no route to host')), (
        DownloadFailure.network,
        null,
      ));
      expect(failureOf(bd.TaskFileSystemException('/secret/path')), (
        DownloadFailure.storage,
        null,
      ));
      expect(failureOf(bd.TaskUrlException('bad')), (
        DownloadFailure.invalidRequest,
        null,
      ));
      expect(failureOf(bd.TaskResumeException('gone')), (
        DownloadFailure.killed,
        null,
      ));
      expect(failureOf(bd.TaskException('?')), (DownloadFailure.other, null));
      expect(failureOf(null), (DownloadFailure.other, null));
    });
  });

  group('a status update', () {
    bd.TaskStatusUpdate update(
      bd.TaskStatus status, [
      bd.TaskException? exception,
      int? code,
    ]) => bd.TaskStatusUpdate(task(), status, exception, null, null, code);

    test('enqueued, retrying and canceled', () {
      expect(
        downloadStatusOf(update(bd.TaskStatus.enqueued))!.status,
        const Queued(),
      );
      expect(
        downloadStatusOf(update(bd.TaskStatus.waitingToRetry))!.status,
        const Waiting(WaitReason.retry),
      );
      expect(
        downloadStatusOf(update(bd.TaskStatus.canceled))!.status,
        const Cancelled(),
      );
    });

    test('running and paused carry the last progress', () {
      const known = Progress(40, 100);
      expect(
        downloadStatusOf(update(bd.TaskStatus.running), known: known)!.status,
        const Running(40, 100),
      );
      expect(
        downloadStatusOf(update(bd.TaskStatus.paused), known: known)!.status,
        const Paused(40, 100),
      );
      expect(
        downloadStatusOf(update(bd.TaskStatus.running))!.status,
        const Running(0),
      );
    });

    test('notFound is a 404 refusal', () {
      final m = downloadStatusOf(update(bd.TaskStatus.notFound))!;
      expect(m.status, const Failed(DownloadFailure.rejected));
      expect(m.httpStatus, 404);
    });

    test('failed reads the exception, with the HTTP status', () {
      final m = downloadStatusOf(
        update(bd.TaskStatus.failed, bd.TaskHttpException('x', 401)),
      )!;
      expect(m.status, const Failed(DownloadFailure.unauthorized));
      expect(m.httpStatus, 401);
      expect(
        downloadStatusOf(update(bd.TaskStatus.failed))!.status,
        const Failed(DownloadFailure.other),
      );
    });

    test('complete is the location and the bytes it is given', () {
      final m = downloadStatusOf(
        update(bd.TaskStatus.complete),
        completeBytes: 7,
      )!;
      expect(
        m.status,
        const Complete(DownloadLocation(DownloadBase.support, 'maps/a.bin'), 7),
      );
    });

    test('complete in a base that is not ours is a failure, not a path', () {
      final m = downloadStatusOf(
        bd.TaskStatusUpdate(
          task(base: bd.BaseDirectory.root),
          bd.TaskStatus.complete,
        ),
      )!;
      expect(m.status, const Failed(DownloadFailure.other));
    });
  });

  group('progress', () {
    test('a fraction of the size is bytes received', () {
      expect(progressOf(0.25, 200), const Progress(50, 200));
      expect(progressOf(1, 200), const Progress(200, 200));
      expect(progressOf(0, 200), const Progress(0, 200));
    });

    test('an unknown size has no total and no count', () {
      expect(progressOf(0.5, -1), Progress.none);
      expect(progressOf(0.5, 0), Progress.none);
    });

    test('the plugin\'s negative end markers are not progress', () {
      for (final marker in [
        bd.progressFailed,
        bd.progressCanceled,
        bd.progressNotFound,
        bd.progressWaitingToRetry,
        bd.progressPaused,
      ]) {
        expect(progressOf(marker, 100), isNull, reason: '$marker');
      }
      expect(progressOf(double.nan, 100), isNull);
    });
  });

  group('notifications', () {
    test('none is an empty plan', () {
      expect(notificationPlanOf(null).isEmpty, isTrue);
      expect(
        const DownloadNotifications() == const DownloadNotifications(),
        isTrue,
      );
      expect(notificationPlanOf(const DownloadNotifications()).isEmpty, isTrue);
    });

    test('each text is a title, with the task\'s display name as the body', () {
      final plan = notificationPlanOf(
        const DownloadNotifications(
          running: 'Downloading',
          paused: 'Paused',
          complete: 'Done',
          failed: 'Failed',
        ),
      );
      expect(plan.running!.title, 'Downloading');
      expect(plan.running!.body, '{displayName}');
      expect(plan.paused!.title, 'Paused');
      expect(plan.complete!.title, 'Done');
      expect(plan.error!.title, 'Failed');
      expect(plan.hasRunning, isTrue);
    });

    test('a state without a text has no notification', () {
      final plan = notificationPlanOf(
        const DownloadNotifications(complete: 'Done'),
      );
      expect(plan.running, isNull);
      expect(plan.hasRunning, isFalse);
      expect(plan.isEmpty, isFalse);
    });
  });
}
