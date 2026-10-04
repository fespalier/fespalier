// What `fespalier_image` (since 0.9.0) reports through `FespalierTelemetry.begin` and `finish`: an
// `image` operation, never with a URL, and optionally under the navigation in progress.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/telemetry.dart'
    show telemetryNavigationEnd, telemetryNavigationStart;
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  test(
    'with no sink, an image operation returns no token and records nothing',
    () {
      FespalierTelemetry.install(null);
      final token = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.image,
          imageCdn: 'emgr',
          imageWidth: 128,
        ),
        underNavigation: true,
      );
      expect(token, isNull);
      FespalierTelemetry.finish(
        token,
        const TelemetryEnd(TelemetryOutcome.ok, isAsync: true),
      );
    },
  );

  test(
    'the recording sink writes the CDN, the width, a preload and a status',
    () {
      final rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
      final fresh = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.image,
          imageCdn: 'emgr',
          imageWidth: 128,
        ),
      );
      FespalierTelemetry.finish(
        fresh,
        const TelemetryEnd(TelemetryOutcome.ok, isAsync: true),
      );
      final preload = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.image,
          imageCdn: 'emgr',
          imageWidth: 640,
          imagePreload: true,
        ),
      );
      final failed = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.image,
          imageCdn: 'cloudinary',
          imageWidth: 32,
        ),
      );
      FespalierTelemetry.finish(
        failed,
        const TelemetryEnd(
          TelemetryOutcome.error,
          isAsync: true,
          imageStatus: 404,
        ),
      );
      FespalierTelemetry.finish(
        preload,
        const TelemetryEnd(TelemetryOutcome.error, isAsync: true),
      );
      expect(rec.log, [
        '#1 start image emgr w=128',
        '#1 end image ok async',
        '#2 start image emgr w=640 preload',
        '#3 start image cloudinary w=32',
        '#3 end image error async status=404',
        '#2 end image error async',
      ]);
    },
  );

  test(
    'underNavigation makes the image a child of the navigation in progress',
    () {
      final rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
      final nav = telemetryNavigationStart(Uri.parse('/products/3'));
      final under = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.image,
          imageCdn: 'emgr',
          imageWidth: 640,
        ),
        underNavigation: true,
      );
      final plain = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.image,
          imageCdn: 'emgr',
          imageWidth: 640,
        ),
      );
      FespalierTelemetry.finish(under, const TelemetryEnd(TelemetryOutcome.ok));
      FespalierTelemetry.finish(plain, const TelemetryEnd(TelemetryOutcome.ok));
      telemetryNavigationEnd(nav, const TelemetryEnd(TelemetryOutcome.ok));
      final after = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.image,
          imageCdn: 'emgr',
          imageWidth: 640,
        ),
        underNavigation: true,
      );
      FespalierTelemetry.finish(after, const TelemetryEnd(TelemetryOutcome.ok));
      expect(rec.log, [
        '#1 start navigate /products/3',
        '#2 start image emgr w=640 parent=#1',
        '#3 start image emgr w=640',
        '#2 end image ok',
        '#3 end image ok',
        '#1 end navigate ok',
        // The navigation is over: nothing to be a child of.
        '#4 start image emgr w=640',
        '#4 end image ok',
      ]);
    },
  );

  test('an operation that has a parent keeps it', () {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    final first = telemetryNavigationStart(Uri.parse('/a'));
    final own = FespalierTelemetry.begin(
      TelemetryStart(
        TelemetryOp.image,
        imageCdn: 'emgr',
        imageWidth: 1,
        parent: first,
      ),
      underNavigation: true,
    );
    FespalierTelemetry.finish(own, const TelemetryEnd(TelemetryOutcome.ok));
    telemetryNavigationEnd(first, const TelemetryEnd(TelemetryOutcome.ok));
    expect(rec.log[1], '#2 start image emgr w=1 parent=#1');
  });

  test('underNavigation copies every field of the start', () {
    final rec = _Capture();
    FespalierTelemetry.install(rec);
    final nav = telemetryNavigationStart(Uri.parse('/p'));
    FespalierTelemetry.begin(
      const TelemetryStart(
        TelemetryOp.image,
        imageCdn: 'imgix',
        imageWidth: 750,
        imagePreload: true,
      ),
      underNavigation: true,
    );
    final copy = rec.starts.last;
    expect(copy.op, TelemetryOp.image);
    expect(copy.imageCdn, 'imgix');
    expect(copy.imageWidth, 750);
    expect(copy.imagePreload, isTrue);
    expect(copy.parent, isNotNull);
    telemetryNavigationEnd(nav, const TelemetryEnd(TelemetryOutcome.ok));
  });
}

final class _Capture extends FespalierTelemetry {
  final List<TelemetryStart> starts = [];

  @override
  Object? start(TelemetryStart start) {
    starts.add(start);
    return starts.length;
  }
}
