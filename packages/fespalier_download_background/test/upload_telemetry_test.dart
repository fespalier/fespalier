// The upload telemetry contract: the names are pinned, and every value is a constant.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download_background/fespalier_download_background.dart';
import 'package:fespalier_download_background/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the names are the contract', () {
    expect(FespalierUploadConventions.transfer, 'fespalier.upload.transfer');
    expect(
      FespalierUploadConventions.background,
      'fespalier.upload.background',
    );
    expect(FespalierUploadConventions.network, 'fespalier.upload.network');
    expect(FespalierUploadConventions.priority, 'fespalier.upload.priority');
    expect(FespalierUploadConventions.encoding, 'fespalier.upload.encoding');
    expect(
      FespalierUploadConventions.replaySafe,
      'fespalier.upload.replay_safe',
    );
    expect(FespalierUploadConventions.result, 'fespalier.upload.result');
    expect(FespalierUploadConventions.failure, 'fespalier.upload.failure');
    expect(FespalierUploadConventions.regranted, 'fespalier.upload.regranted');
    expect(
      FespalierUploadConventions.reconciled,
      'fespalier.upload.reconciled',
    );
    expect(
      [
        FespalierUploadConventions.resultComplete,
        FespalierUploadConventions.resultFailed,
        FespalierUploadConventions.resultCancelled,
      ],
      ['complete', 'failed', 'cancelled'],
    );
    expect(UploadEncoding.values.map((v) => v.name), ['multipart', 'binary']);
    expect(UploadMethod.values.map((v) => v.name), ['post', 'put']);
  });

  test(
    'no name sits in the downloads\' namespace, so no download name changed',
    () {
      for (final name in [
        FespalierUploadConventions.transfer,
        FespalierUploadConventions.background,
        FespalierUploadConventions.network,
        FespalierUploadConventions.priority,
        FespalierUploadConventions.encoding,
        FespalierUploadConventions.replaySafe,
        FespalierUploadConventions.result,
        FespalierUploadConventions.failure,
        FespalierUploadConventions.regranted,
        FespalierUploadConventions.reconciled,
      ]) {
        expect(name, startsWith('fespalier.upload.'));
        expect(name, isNot(contains('url')));
        expect(name, isNot(contains('path')));
        expect(name, isNot(contains('field')));
      }
    },
  );

  test('a span carries the request\'s enum names and booleans, nothing of its text', () async {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    addTearDown(() => FespalierTelemetry.install(null));
    final backend = FakeUploadBackend();
    final engine = Uploads(backend: backend, store: MemoryUploadStore());
    await engine.open();
    final request = UploadRequest(
      id: 'private-id',
      url: Uri.parse('https://private.example.com/x?t=SECRET'),
      file: const DownloadLocation(DownloadBase.support, 'private/path.jpg'),
      fields: const {'privateField': 'privateValue'},
      headers: const {'Authorization': 'SECRET'},
      displayName: 'Private Name',
    );
    await engine.start(request);
    backend.emit('private-id', const Failed(DownloadFailure.network));
    final text = rec.log.join('\n');
    expect(text, contains('fespalier.upload.transfer'));
    for (final secret in [
      'private',
      'SECRET',
      'Private Name',
      'path.jpg',
      'privateField',
    ]) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
  });
}
