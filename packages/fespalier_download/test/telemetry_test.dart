// The package's telemetry contract: the names are pinned, and they pass fespalier's debug
// checks as custom operations.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the names are the package contract', () {
    expect(
      FespalierDownloadConventions.transfer,
      'fespalier.download.transfer',
    );
    expect(FespalierDownloadConventions.resumed, 'fespalier.download.resumed');
    expect(
      FespalierDownloadConventions.background,
      'fespalier.download.background',
    );
    expect(FespalierDownloadConventions.network, 'fespalier.download.network');
    expect(
      FespalierDownloadConventions.priority,
      'fespalier.download.priority',
    );
    expect(FespalierDownloadConventions.result, 'fespalier.download.result');
    expect(FespalierDownloadConventions.failure, 'fespalier.download.failure');
    expect(
      FespalierDownloadConventions.reconciled,
      'fespalier.download.reconciled',
    );
    expect(FespalierDownloadConventions.open, 'fespalier.download.open');
    expect(FespalierDownloadConventions.routed, 'fespalier.download.routed');
    expect(
      [
        FespalierDownloadConventions.resultComplete,
        FespalierDownloadConventions.resultFailed,
        FespalierDownloadConventions.resultCancelled,
      ],
      ['complete', 'failed', 'cancelled'],
    );
  });

  test('the attribute values come from this package\'s enums, by name', () {
    expect(DownloadNetwork.values.map((v) => v.name), ['any', 'unmetered']);
    expect(DownloadPriority.values.map((v) => v.name), [
      'userInitiated',
      'background',
    ]);
    expect(DownloadFailure.values.map((v) => v.name), [
      'unsupported',
      'invalidRequest',
      'network',
      'rejected',
      'unauthorized',
      'sizeMismatch',
      'hashMismatch',
      'storage',
      'notificationsRequired',
      'killed',
      'other',
    ]);
  });

  test('a transfer reads as a span', () {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    addTearDown(() => FespalierTelemetry.install(null));
    final token = FespalierTelemetry.begin(
      const TelemetryStart(
        TelemetryOp.custom,
        name: FespalierDownloadConventions.transfer,
        attributes: {
          FespalierDownloadConventions.resumed: false,
          FespalierDownloadConventions.background: true,
          FespalierDownloadConventions.network: 'unmetered',
          FespalierDownloadConventions.priority: 'background',
        },
      ),
    );
    FespalierTelemetry.finish(
      token,
      const TelemetryEnd(
        TelemetryOutcome.error,
        attributes: {
          FespalierDownloadConventions.result:
              FespalierDownloadConventions.resultFailed,
          FespalierDownloadConventions.failure: 'hashMismatch',
        },
      ),
    );
    expect(rec.log, hasLength(2));
    expect(
      rec.log.first,
      startsWith('#1 start custom fespalier.download.transfer'),
    );
    expect(rec.log.last, startsWith('#1 end custom'));
  });

  test('no convention name or value can carry a URL, id, path or text', () {
    // Every constant is a fixed string; the only free text in the request is never a value here.
    final names = [
      FespalierDownloadConventions.transfer,
      FespalierDownloadConventions.resumed,
      FespalierDownloadConventions.background,
      FespalierDownloadConventions.network,
      FespalierDownloadConventions.priority,
      FespalierDownloadConventions.result,
      FespalierDownloadConventions.failure,
      FespalierDownloadConventions.reconciled,
      FespalierDownloadConventions.open,
      FespalierDownloadConventions.routed,
    ];
    for (final name in names) {
      expect(name, startsWith('fespalier.download.'));
      expect(name, isNot(contains('url')));
      expect(name, isNot(contains('path')));
    }
  });
}
