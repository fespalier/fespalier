// The conversions of lib/maplibre.dart that need no platform channel: MapLibre's native progress is
// a percentage (100.0 * completed / required, on both platforms), the port's is a fraction.
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/maplibre.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

void main() {
  test('a percentage becomes a fraction in 0 to 1', () {
    expect(progressFraction(0), 0);
    expect(progressFraction(50), 0.5);
    expect(progressFraction(100), 1);
    expect(progressFraction(150), 1, reason: 'clamped');
    expect(progressFraction(-3), 0);
    expect(progressFraction(double.nan), 0);
  });

  test('download events carry the fraction and the resource counts', () {
    final event = downloadEventOf(
      ml.InProgress(
        25,
        completedResourceCount: 5,
        requiredResourceCount: 20,
        completedResourceSize: 1024,
      ),
    );
    expect(event, isA<DownloadProgress>());
    final progress = event as DownloadProgress;
    expect(progress.progress, 0.25);
    expect(progress.completedResources, 5);
    expect(progress.requiredResources, 20);
    expect(progress.bytes, 1024);
    expect(downloadEventOf(ml.Success()), isA<DownloadFinished>());
  });

  test('an error event maps its code to a failure and keeps no text', () {
    final failed =
        downloadEventOf(
              ml.Error(
                PlatformException(
                  code: 'tileCountLimitExceeded',
                  message: 'https://secret',
                ),
              ),
            )
            as DownloadFailed;
    expect(failed.reason, PackFailure.limitExceeded);
    final replaced =
        downloadEventOf(ml.Error(PlatformException(code: 'RegionReplaced')))
            as DownloadFailed;
    expect(replaced.reason, PackFailure.replaced);
  });

  test('a region status converts its percentage too', () {
    final status = regionStatusOf(
      const ml.OfflineRegionStatus(
        completedResourceCount: 30,
        requiredResourceCount: 40,
        completedResourceSize: 4096,
        isComplete: false,
        downloadProgress: 75,
      ),
    );
    expect(status.progress, 0.75);
    expect(status.bytes, 4096);
    expect(status.isComplete, isFalse);
  });
}
