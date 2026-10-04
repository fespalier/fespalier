import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/telemetry.dart'
    show telemetryNavigationEnd, telemetryNavigationStart;
import 'package:fespalier/testing.dart';
import 'package:fespalier_image/fespalier_image.dart';
import 'package:fespalier_image/src/telemetry.dart';
import 'package:fespalier_image/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUpAll(makeTestImage);
  setUp(resetImageState);
  tearDown(() => FespalierTelemetry.install(null));

  final url128 = productUrl(128, height: 128);

  testWidgets('a fresh load is a span, and a load that was in the cache is not', (
    tester,
  ) async {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    final fakes = FakeImages(image: testImage);
    await tester.pumpWidget(
      imageApp(
        fakes,
        const ResponsiveImage('products/3.jpg', width: 40, aspectRatio: 1),
      ),
    );
    expect(rec.log, ['#1 start image emgr w=128', '#1 end image ok async']);

    // The same image again, in another widget: the cache has it, so there is no load and no span.
    await tester.pumpWidget(
      imageApp(
        fakes,
        const Column(
          children: [
            ResponsiveImage('products/3.jpg', width: 40, aspectRatio: 1),
            ResponsiveImage('products/3.jpg', width: 40, aspectRatio: 1),
          ],
        ),
      ),
    );
    expect(rec.log, hasLength(2));
    expect(fakes.requested, [url128]);
  });

  testWidgets(
    'a pending load ends when it completes, and a failure carries its status',
    (tester) async {
      final rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
      final fakes = FakeImages();
      await tester.pumpWidget(
        imageApp(
          fakes,
          const Column(
            children: [
              ResponsiveImage('products/1.jpg', width: 40, aspectRatio: 1),
              ResponsiveImage('products/2.jpg', width: 40, aspectRatio: 1),
            ],
          ),
        ),
      );
      expect(rec.log, [
        '#1 start image emgr w=128',
        '#2 start image emgr w=128',
      ]);
      fakes.complete(productUrl(128, height: 128, b64: b64Product1), testImage);
      fakes.fail(productUrl(128, height: 128, b64: b64Product2));
      await tester.pump();
      expect(rec.log, [
        '#1 start image emgr w=128',
        '#2 start image emgr w=128',
        '#1 end image ok async',
        '#2 end image error async status=404',
      ]);
    },
  );

  testWidgets(
    'a failure that is not an HTTP one has no status, and never its text',
    (tester) async {
      final rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
      final fakes = FakeImages();
      await tester.pumpWidget(
        imageApp(
          fakes,
          const ResponsiveImage('products/3.jpg', width: 40, aspectRatio: 1),
        ),
      );
      fakes.fail(
        url128,
        const FormatException(
          'https://images.example.com/products/3.jpg is not an image',
        ),
      );
      await tester.pump();
      expect(rec.log, [
        '#1 start image emgr w=128',
        '#1 end image error async',
      ]);
    },
  );

  testWidgets('the log never has a URL, a source or a signature', (
    tester,
  ) async {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    final fakes = FakeImages();
    await tester.pumpWidget(
      imageApp(
        fakes,
        const ResponsiveImage('products/3.jpg', width: 40, aspectRatio: 1),
      ),
    );
    fakes.fail(url128);
    await tester.pump();
    for (final line in rec.log) {
      expect(line, isNot(contains('http')));
      expect(line, isNot(contains('products')));
      expect(line, isNot(contains(b64Product3)));
    }
  });

  testWidgets('a precache is a span with preload', (tester) async {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    final fakes = FakeImages(image: testImage);
    late BuildContext context;
    await tester.pumpWidget(
      imageApp(
        fakes,
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    unawaited(
      ResponsiveImage.precache(
        context,
        'products/3.jpg',
        width: 160,
        aspectRatio: 1,
      ),
    );
    expect(rec.log, [
      '#1 start image emgr w=640 preload',
      '#1 end image ok async',
    ]);

    // The page then finds it in the cache: nothing more.
    await tester.pumpWidget(
      imageApp(
        fakes,
        const ResponsiveImage('products/3.jpg', width: 160, aspectRatio: 1),
      ),
    );
    expect(rec.log, hasLength(2));
  });

  testWidgets(
    'an image that starts while a page is being reached is a child of that navigation',
    (tester) async {
      final rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
      final nav = telemetryNavigationStart(Uri.parse('/products/3'));
      final fakes = FakeImages(image: testImage);
      await tester.pumpWidget(
        imageApp(
          fakes,
          const ResponsiveImage('products/3.jpg', width: 40, aspectRatio: 1),
        ),
      );
      telemetryNavigationEnd(nav, const TelemetryEnd(TelemetryOutcome.ok));
      expect(rec.log, [
        '#1 start navigate /products/3',
        '#2 start image emgr w=128 parent=#1',
        '#2 end image ok async',
        '#1 end navigate ok',
      ]);
    },
  );

  testWidgets('an image in a hero flight starts no load and no span', (
    tester,
  ) async {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    final fakes = FakeImages(image: testImage);
    await tester.pumpWidget(
      imageApp(
        fakes,
        const ResponsiveImageFlight(
          child: ResponsiveImage('products/3.jpg', width: 40, aspectRatio: 1),
        ),
      ),
    );
    expect(fakes.requested, isEmpty);
    expect(rec.log, isEmpty);
  });

  test(
    'with no sink nothing is resolved: no span, and no listener on the image',
    () {
      FespalierTelemetry.install(null);
      expect(imageTelemetryOn, isFalse);
      final fakes = FakeImages();
      traceImageLoad(
        fakes.provider(url128),
        ImageConfiguration.empty,
        cdn: 'emgr',
        width: 128,
        preload: false,
      );
      // It did not even resolve the provider, which would have started the load.
      expect(fakes.requested, isEmpty);
    },
  );

  test('a load that is already in flight makes no second span', () {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    final fakes = FakeImages();
    final provider = fakes.provider(url128);
    void trace() => traceImageLoad(
      provider,
      ImageConfiguration.empty,
      cdn: 'emgr',
      width: 128,
      preload: false,
    );
    TestWidgetsFlutterBinding.ensureInitialized();
    trace();
    trace();
    expect(rec.log, ['#1 start image emgr w=128']);
    expect(fakes.requested, [url128]);
    fakes.complete(url128, testImage);
  });

  test('a sync load with a sink installed schedules no microtask', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    final fakes = FakeImages(image: testImage);
    var microtasks = 0;
    runZoned(
      () => traceImageLoad(
        fakes.provider(url128),
        ImageConfiguration.empty,
        cdn: 'emgr',
        width: 128,
        preload: false,
      ),
      zoneSpecification: ZoneSpecification(
        scheduleMicrotask: (self, parent, zone, f) {
          microtasks++;
          parent.scheduleMicrotask(zone, f);
        },
      ),
    );
    expect(rec.log, ['#1 start image emgr w=128', '#1 end image ok async']);
    expect(microtasks, 0);
  });

  test('a sink that throws costs the span, not the image', () {
    FespalierTelemetry.install(_Throwing());
    TestWidgetsFlutterBinding.ensureInitialized();
    final printed = <String>[];
    final saved = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    final fakes = FakeImages(image: testImage);
    try {
      traceImageLoad(
        fakes.provider(url128),
        ImageConfiguration.empty,
        cdn: 'emgr',
        width: 128,
        preload: false,
      );
    } finally {
      debugPrint = saved;
    }
    expect(fakes.requested, [url128]);
    // fespalier prints the sink's error once, and the image goes on.
    expect(printed.length, lessThanOrEqualTo(1));
  });
}

final class _Throwing extends FespalierTelemetry {
  @override
  Object? start(TelemetryStart start) => throw StateError('start');

  @override
  void end(Object? token, TelemetryEnd end) => throw StateError('end');
}
