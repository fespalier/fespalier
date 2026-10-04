import 'dart:async';

import 'package:fespalier/fespalier.dart' show ProviderScope;
import 'package:fespalier_image/fespalier_image.dart';
import 'package:fespalier_image/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUpAll(makeTestImage);
  setUp(resetImageState);

  /// Pumps an app and returns a context under its `ProviderScope`.
  Future<BuildContext> contextOf(WidgetTester tester, FakeImages fakes) async {
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
    return context;
  }

  testWidgets(
    'precache asks for the URL the page will ask for, which then shows at once',
    (tester) async {
      final fakes = FakeImages(image: testImage);
      final context = await contextOf(tester, fakes);
      unawaited(
        ResponsiveImage.precache(
          context,
          'products/3.jpg',
          width: 160,
          aspectRatio: 1,
        ),
      );
      expect(fakes.requested, [productUrl(640, height: 640)]);

      await tester.pumpWidget(
        imageApp(
          fakes,
          const ResponsiveImage(
            'products/3.jpg',
            width: 160,
            aspectRatio: 1,
            placeholder: testPlaceholder,
          ),
        ),
      );
      expect(fakes.requested, hasLength(1));
      expect(placeholder, findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    },
  );

  testWidgets(
    'a precache that was pending shows at once when it has completed',
    (tester) async {
      final fakes = FakeImages();
      final context = await contextOf(tester, fakes);
      var done = false;
      unawaited(
        ResponsiveImage.precache(
          context,
          'products/3.jpg',
          width: 160,
          aspectRatio: 1,
        ).then((_) => done = true),
      );
      final url = productUrl(640, height: 640);
      expect(fakes.isPending(url), isTrue);
      fakes.complete(url, testImage);
      await tester.pump();
      expect(done, isTrue);

      await tester.pumpWidget(
        imageApp(
          fakes,
          const ResponsiveImage(
            'products/3.jpg',
            width: 160,
            aspectRatio: 1,
            placeholder: testPlaceholder,
          ),
        ),
      );
      expect(fakes.requested, [url]);
      expect(placeholder, findsNothing);
    },
  );

  testWidgets('without a width it asks for the view\'s width', (tester) async {
    final fakes = FakeImages(image: testImage);
    final context = await contextOf(tester, fakes);
    unawaited(
      ResponsiveImage.precache(context, 'products/3.jpg', aspectRatio: 1),
    );
    // 800 logical at a ratio of 3.
    expect(fakes.requested, [productUrl(3840, height: 3840)]);
  });

  testWidgets(
    'a width and a height are an aspect ratio, and the call\'s options reach the URL',
    (tester) async {
      final fakes = FakeImages(image: testImage);
      final context = await contextOf(tester, fakes);
      unawaited(
        ResponsiveImage.precache(
          context,
          'products/3.jpg',
          width: 40,
          height: 40,
          format: ImageFormat.png,
          quality: 70,
        ),
      );
      expect(fakes.requested, [
        'http://localhost:13001/unsigned/rs:fill:128:128/q:70/$b64Product3.png',
      ]);
    },
  );

  testWidgets('a failing precache is dropped and leaves no exception', (
    tester,
  ) async {
    final fakes = FakeImages();
    final context = await contextOf(tester, fakes);
    var done = false;
    unawaited(
      ResponsiveImage.precache(
        context,
        'products/3.jpg',
        width: 160,
        aspectRatio: 1,
      ).then((_) => done = true),
    );
    fakes.fail(productUrl(640, height: 640));
    await tester.pump();
    expect(done, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a misconfigured builder is reported with "while precaching" and returns at once',
    (tester) async {
      final fakes = FakeImages();
      final context = await contextOf(tester, fakes);
      final details = <FlutterErrorDetails>[];
      final saved = FlutterError.onError;
      FlutterError.onError = details.add;
      Future<void> future;
      try {
        future = ResponsiveImage.precache(
          context,
          'products/3.jpg',
          width: 160,
          builder: const TemplateUrlBuilder('{nope}'),
        );
      } finally {
        FlutterError.onError = saved;
      }
      expect(details, hasLength(1));
      expect(details.single.library, 'fespalier_image');
      expect(
        details.single.context.toString(),
        'while precaching the image "products/3.jpg"',
      );
      expect(details.single.exception, isA<ImageUrlError>());
      expect(fakes.requested, isEmpty);
      await future;
    },
  );

  testWidgets('a width that is not positive fetches nothing', (tester) async {
    final fakes = FakeImages(image: testImage);
    final context = await contextOf(tester, fakes);
    await ResponsiveImage.precache(context, 'products/3.jpg', width: 0);
    expect(fakes.requested, isEmpty);
  });

  testWidgets('a nested ProviderScope\'s CDN is the one precached through', (
    tester,
  ) async {
    final outer = FakeImages(image: testImage);
    final inner = FakeImages(image: testImage);
    late BuildContext context;
    await tester.pumpWidget(
      imageApp(
        outer,
        ProviderScope(
          overrides: [imageCdnProvider.overrideWithValue(inner.cdn(emgr))],
          child: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    unawaited(ResponsiveImage.precache(context, 'products/3.jpg', width: 40));
    expect(outer.requested, isEmpty);
    expect(inner.requested, [productUrl(128)]);
  });
}
