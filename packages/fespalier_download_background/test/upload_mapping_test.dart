// An UploadRequest as a background_downloader 9.6.4 UploadTask, and the replay-safety table at
// the layer that decides what the platform may retry. Pure: no plugin call.
import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download_background/fespalier_download_background.dart';
import 'package:flutter_test/flutter_test.dart';

const _file = DownloadLocation(DownloadBase.documents, 'outbox/photo.jpg');

UploadRequest request({
  String id = 'u',
  DownloadLocation file = _file,
  UploadMethod method = UploadMethod.post,
  UploadEncoding encoding = UploadEncoding.multipart,
  String fileField = 'file',
  Map<String, String> fields = const {},
  Map<String, String> headers = const {},
  DownloadNetwork network = DownloadNetwork.any,
  DownloadPriority priority = DownloadPriority.background,
  Uri? url,
}) => UploadRequest(
  id: id,
  url: url ?? Uri.parse('https://api.example.com/upload'),
  file: file,
  method: method,
  encoding: encoding,
  fileField: fileField,
  fields: fields,
  headers: headers,
  network: network,
  priority: priority,
);

void main() {
  group('the replay-safety table', () {
    // method x Idempotency-Key -> replay safe, and so the platform's retries.
    const key = {'Idempotency-Key': 'k-1'};
    final table = <(UploadMethod, Map<String, String>, bool)>[
      (UploadMethod.post, const {}, false),
      (UploadMethod.put, const {}, false),
      (UploadMethod.post, key, true),
      (UploadMethod.put, key, true),
      (UploadMethod.post, {'idempotency-key': 'k'}, true),
      (UploadMethod.post, {'X-Other': '1'}, false),
    ];

    for (final (method, headers, safe) in table) {
      test('${method.name} with ${headers.keys} is replay safe: $safe', () {
        final r = request(method: method, headers: headers);
        expect(r.replaySafe, safe);
        final task = uploadTaskOf(
          r,
          options: const BackgroundOptions(retries: 4),
        );
        expect(task.retries, safe ? 4 : 0);
      });
    }

    test(
      'an upload task never pauses, so there is no pause cycle to resend it',
      () {
        expect(uploadTaskOf(request()).allowPause, isFalse);
        expect(
          uploadTaskOf(request(priority: DownloadPriority.userInitiated))
              .allowPause,
          isFalse,
        );
      },
    );

    test('a retried safe upload still gets the default retries, an unsafe one never', () {
      expect(
        uploadTaskOf(request(headers: {'Idempotency-Key': 'a'})).retries,
        const BackgroundOptions().retries,
      );
      expect(uploadTaskOf(request()).retries, 0);
    });
  });

  group('the task', () {
    test(
      'multipart carries the field name and the fields; POST by default',
      () {
        final t = uploadTaskOf(
          request(fileField: 'avatar', fields: {'user': '7', 'kind': 'a b'}),
        );
        expect(t.httpRequestMethod, 'POST');
        expect(t.post, isNull);
        expect(t.fileField, 'avatar');
        expect(t.fields, {'user': '7', 'kind': 'a b'});
        expect(t.mimeType, 'image/jpeg');
      },
    );

    test('binary is post: binary, and PUT is a PUT', () {
      final t = uploadTaskOf(
        request(method: UploadMethod.put, encoding: UploadEncoding.binary),
      );
      expect(t.httpRequestMethod, 'PUT');
      expect(t.post, 'binary');
      expect(t.fields, isEmpty);
    });

    test('the file is a base, a sub-folder and a name, never absolute', () {
      final t = uploadTaskOf(request());
      expect(t.baseDirectory, bd.BaseDirectory.applicationDocuments);
      expect(t.directory, 'outbox');
      expect(t.filename, 'photo.jpg');
      expect(locationOf(t), _file);
      final flat = uploadTaskOf(
        request(file: const DownloadLocation(DownloadBase.support, 'a.bin')),
      );
      expect(flat.directory, '');
      expect(flat.baseDirectory, bd.BaseDirectory.applicationSupport);
    });

    test('its own group, the request id, status and progress updates', () {
      final t = uploadTaskOf(request(id: 'abc'));
      expect(t.group, backgroundUploadGroup);
      expect(backgroundUploadGroup, isNot(backgroundDownloadGroup));
      expect(t.taskId, 'abc');
      expect(t.updates, bd.Updates.statusAndProgress);
      expect(defaultUploadOptions.group, backgroundUploadGroup);
    });

    test('priority, network and headers', () {
      expect(
        uploadTaskOf(request(priority: DownloadPriority.userInitiated))
            .priority,
        userInitiatedPriority,
      );
      expect(uploadTaskOf(request()).priority, backgroundPriority);
      expect(
        uploadTaskOf(request(network: DownloadNetwork.unmetered)).requiresWiFi,
        isTrue,
      );
      final t = uploadTaskOf(
        request(headers: {'A': '1', 'B': '2'}),
        authorization: {'B': 'grant', 'C': '3'},
      );
      expect(t.headers, {'A': '1', 'B': 'grant', 'C': '3'});
    });

    test('a completed upload maps to Complete at the file that was sent', () {
      final t = uploadTaskOf(request());
      final mapped = downloadStatusOf(
        bd.TaskStatusUpdate(t, bd.TaskStatus.complete),
        completeBytes: 12,
      );
      expect(mapped?.status, const Complete(_file, 12));
    });

    test('a server refusal keeps its HTTP status', () {
      final t = uploadTaskOf(request());
      final mapped = downloadStatusOf(
        bd.TaskStatusUpdate(
          t,
          bd.TaskStatus.failed,
          bd.TaskHttpException('no', 401),
        ),
      );
      expect(mapped?.status, const Failed(DownloadFailure.unauthorized));
      expect(mapped?.httpStatus, 401);
    });
  });

  group('the request', () {
    test('toString prints no field', () {
      final r = request(
        url: Uri.parse('https://api.example.com/up?token=SECRET'),
        headers: {'Authorization': 'Bearer SECRET'},
        fields: {'who': 'Secret Person'},
      );
      expect(r.toString(), 'UploadRequest');
      expect('$r', isNot(contains('SECRET')));
      expect(
        StoredUpload(UploadRequest(id: 'a', url: _u, file: _file)).toString(),
        'StoredUpload',
      );
    });

    test('validation', () {
      expect(request().isValid, isTrue);
      expect(request(id: '').isValid, isFalse);
      expect(request(url: Uri.parse('ftp://x/y')).isValid, isFalse);
      expect(request(url: Uri.parse('/relative')).isValid, isFalse);
      expect(request(url: Uri.parse('https://u:p@x/y')).isValid, isFalse);
      for (final bad in [
        '/abs/photo.jpg',
        '../photo.jpg',
        'a/../b.jpg',
        r'a\b.jpg',
        'a\u0000b',
        '',
        'a//b',
      ]) {
        expect(
          request(file: DownloadLocation(DownloadBase.support, bad)).isValid,
          isFalse,
          reason: bad,
        );
      }
      expect(request(headers: {' ': 'x'}).isValid, isFalse);
      expect(request(fileField: '').isValid, isFalse);
      expect(request(fileField: 'a"b').isValid, isFalse);
      expect(request(fields: {'a\nb': '1'}).isValid, isFalse);
      expect(
        request(encoding: UploadEncoding.binary, fields: {'a': '1'}).isValid,
        isFalse,
      );
      expect(request(encoding: UploadEncoding.binary).isValid, isTrue);
    });

    test('withUrl changes the address and nothing else', () {
      final r = request(
        headers: {'Idempotency-Key': 'k'},
        fields: {'a': '1'},
        priority: DownloadPriority.userInitiated,
      );
      final g = r.withUrl(Uri.parse('https://cdn.example.com/signed'));
      expect(g.url.host, 'cdn.example.com');
      expect(g.id, r.id);
      expect(g.file, r.file);
      expect(g.fields, r.fields);
      expect(g.headers, r.headers);
      expect(g.priority, r.priority);
      expect(g.replaySafe, isTrue);
    });
  });
}

final _u = Uri.parse('https://x.example.com/');
