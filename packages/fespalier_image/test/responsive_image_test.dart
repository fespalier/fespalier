import 'package:fespalier/fespalier.dart' show ProviderScope;
import 'package:fespalier_image/fespalier_image.dart';
import 'package:fespalier_image/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUpAll(makeTestImage);
  setUp(resetImageState);

  Widget sized(FakeImages fakes, double width, {bool grow = false}) => imageApp(
    fakes,
    SizedBox(
      width: width,
      child: ResponsiveImage(
        'products/3.jpg',
        aspectRatio: 1,
        growWithBox: grow,
        placeholder: testPlaceholder,
      ),
    ),
  );

  testWidgets(
    '(a) a 40x40 image asks for the 128 URL and shows it in the first frame',
    (tester) async {
      final fakes = FakeImages(image: testImage);
      await tester.pumpWidget(
        imageApp(
          fakes,
          const ResponsiveImage('products/3.jpg', width: 40, height: 40),
        ),
      );
      expect(fakes.requested, [productUrl(128, height: 128)]);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      expect(tester.getSize(find.byType(ResponsiveImage)), const Size(40, 40));
    },
  );

  testWidgets(
    '(b) a pending load shows the placeholder, a completed one the image',
    (tester) async {
      final fakes = FakeImages();
      await tester.pumpWidget(
        imageApp(
          fakes,
          const ResponsiveImage(
            'products/3.jpg',
            width: 40,
            aspectRatio: 1,
            placeholder: testPlaceholder,
          ),
        ),
      );
      final url = productUrl(128, height: 128);
      expect(fakes.requested, [url]);
      expect(fakes.isPending(url), isTrue);
      expect(placeholder, findsOneWidget);
      fakes.complete(url, testImage);
      await tester.pump();
      expect(fakes.isPending(url), isFalse);
      expect(placeholder, findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    },
  );

  testWidgets('(c) a failed load shows the error view, retry asks again', (
    tester,
  ) async {
    final fakes = FakeImages();
    await tester.pumpWidget(
      imageApp(
        fakes,
        ResponsiveImage(
          'products/3.jpg',
          width: 40,
          aspectRatio: 1,
          placeholder: testPlaceholder,
          errorBuilder: (context, error, retry) => TextButton(
            key: const Key('retry'),
            onPressed: retry,
            child: Text('failed: ${error.runtimeType}'),
          ),
        ),
      ),
    );
    final url = productUrl(128, height: 128);
    fakes.fail(url);
    await tester.pump();
    expect(find.text('failed: NetworkImageLoadException'), findsOneWidget);
    expect(fakes.requested, [url]);

    await tester.tap(find.byKey(const Key('retry')));
    await tester.pump();
    expect(fakes.requested, [url, url]);
    expect(placeholder, findsOneWidget);
    expect(fakes.isPending(url), isTrue);

    fakes.complete(url, testImage);
    await tester.pump();
    expect(find.byKey(const Key('retry')), findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
  });

  testWidgets('the default error view is a box with a broken-image icon', (
    tester,
  ) async {
    final fakes = FakeImages();
    await tester.pumpWidget(
      imageApp(
        fakes,
        const ResponsiveImage('products/3.jpg', width: 40, height: 40),
      ),
    );
    fakes.fail(productUrl(128, height: 128));
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
  });

  group('(d) the latch', () {
    testWidgets('a box that grows asks for nothing new', (tester) async {
      final fakes = FakeImages(image: testImage);
      await tester.pumpWidget(sized(fakes, 40));
      expect(fakes.requested, [productUrl(128, height: 128)]);
      await tester.pumpWidget(sized(fakes, 100));
      await tester.pumpWidget(sized(fakes, 160));
      expect(fakes.requested, [productUrl(128, height: 128)]);
    });

    testWidgets(
      'with growWithBox it asks for a wider one once, and never a narrower',
      (tester) async {
        final fakes = FakeImages(image: testImage);
        await tester.pumpWidget(sized(fakes, 40, grow: true));
        await tester.pumpWidget(sized(fakes, 100, grow: true));
        // 100 logical is 300 physical, past the 128 bucket: it grows once.
        expect(fakes.requested, [
          productUrl(128, height: 128),
          productUrl(384, height: 384),
        ]);
        await tester.pumpWidget(sized(fakes, 160, grow: true));
        expect(fakes.requested.last, productUrl(640, height: 640));
        await tester.pumpWidget(sized(fakes, 160, grow: true));
        await tester.pumpWidget(sized(fakes, 40, grow: true));
        expect(fakes.requested, hasLength(3));
      },
    );

    testWidgets('an animated box asks once, the way a hero flight\'s does', (
      tester,
    ) async {
      final fakes = FakeImages(image: testImage);
      await tester.pumpWidget(sized(fakes, 40));
      for (var w = 40.0; w <= 160; w += 20) {
        await tester.pumpWidget(sized(fakes, w));
      }
      expect(fakes.requested, hasLength(1));
    });
  });

  group('(e) the view', () {
    Widget fullWidth(FakeImages fakes) => imageApp(
      fakes,
      const ResponsiveImage('products/3.jpg', placeholder: testPlaceholder),
    );

    testWidgets('a lower device pixel ratio asks for nothing', (tester) async {
      final fakes = FakeImages(image: testImage);
      await tester.pumpWidget(sized(fakes, 40));
      expect(fakes.requested, hasLength(1));
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pump();
      expect(fakes.requested, hasLength(1));
    });

    testWidgets('a higher one asks for the wider bucket', (tester) async {
      final fakes = FakeImages(image: testImage);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(sized(fakes, 100));
      expect(fakes.requested, [productUrl(128, height: 128)]);
      tester.view.devicePixelRatio = 3;
      await tester.pump();
      expect(fakes.requested.last, productUrl(384, height: 384));
      expect(fakes.requested, hasLength(2));
    });

    testWidgets(
      'a wider view asks for the wider bucket, a narrower one asks for nothing',
      (tester) async {
        final fakes = FakeImages(image: testImage);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 600);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(fullWidth(fakes));
        // 800 logical, 800 physical: the 828 bucket.
        expect(fakes.requested, [productUrl(828)]);
        tester.view.physicalSize = const Size(1200, 600);
        await tester.pump();
        expect(fakes.requested, [productUrl(828), productUrl(1200)]);
        tester.view.physicalSize = const Size(600, 600);
        await tester.pump();
        expect(fakes.requested, hasLength(2));
      },
    );
  });

  testWidgets(
    '(f) while a wider variant loads, the loaded one shows, not the placeholder',
    (tester) async {
      final fakes = FakeImages();
      await tester.pumpWidget(sized(fakes, 40, grow: true));
      final small = productUrl(128, height: 128);
      fakes.complete(small, testImage);
      await tester.pump();
      expect(placeholder, findsNothing);

      await tester.pumpWidget(sized(fakes, 160, grow: true));
      final large = productUrl(640, height: 640);
      expect(fakes.isPending(large), isTrue);
      expect(placeholder, findsNothing);
      final raw = tester.widgetList<RawImage>(find.byType(RawImage)).toList();
      expect(raw, isNotEmpty);
      expect(raw.every((r) => r.image != null), isTrue);

      fakes.complete(large, testImage);
      await tester.pump();
      expect(placeholder, findsNothing);
    },
  );

  testWidgets(
    '(f) a thumbnail another widget loaded stands in for a first load',
    (tester) async {
      final fakes = FakeImages();
      Widget page({required bool large}) => imageApp(
        fakes,
        Column(
          children: [
            const ResponsiveImage('products/3.jpg', width: 40, aspectRatio: 1),
            if (large)
              const ResponsiveImage(
                'products/3.jpg',
                width: 160,
                aspectRatio: 1,
                placeholder: testPlaceholder,
              ),
          ],
        ),
      );
      await tester.pumpWidget(page(large: false));
      fakes.complete(productUrl(128, height: 128), testImage);
      await tester.pump();

      await tester.pumpWidget(page(large: true));
      expect(fakes.requested, [
        productUrl(128, height: 128),
        productUrl(640, height: 640),
      ]);
      // The large one is pending, and shows the thumbnail that is already loaded.
      expect(fakes.isPending(productUrl(640, height: 640)), isTrue);
      expect(placeholder, findsNothing);
      expect(find.byType(RawImage), findsNWidgets(2));
    },
  );

  testWidgets('(g) the widget\'s own arguments reach the URL', (tester) async {
    final fakes = FakeImages(image: testImage);
    await tester.pumpWidget(
      imageApp(
        fakes,
        const ResponsiveImage(
          'products/3.jpg',
          width: 40,
          aspectRatio: 1,
          format: ImageFormat.png,
          quality: 70,
          extra: ['bl:2'],
        ),
      ),
    );
    expect(fakes.requested, [
      'http://localhost:13001/unsigned/rs:fill:128:128/q:70/bl:2/$b64Product3.png',
    ]);

    final template = FakeImages(image: testImage);
    await tester.pumpWidget(
      imageApp(
        template,
        const ResponsiveImage(
          'products/3.jpg',
          width: 40,
          builder: TemplateUrlBuilder(
            'https://cdn.example.com/{source}?w={width}',
          ),
          buckets: ImageBuckets([100, 200]),
        ),
      ),
    );
    expect(template.requested, [
      'https://cdn.example.com/products/3.jpg?w=200',
    ]);
  });

  testWidgets('a new source or new options choose again from scratch', (
    tester,
  ) async {
    final fakes = FakeImages(image: testImage);
    Widget image(String source, {int? quality}) =>
        imageApp(fakes, ResponsiveImage(source, width: 40, quality: quality));
    await tester.pumpWidget(image('products/1.jpg'));
    await tester.pumpWidget(image('products/2.jpg'));
    await tester.pumpWidget(image('products/2.jpg', quality: 50));
    expect(fakes.requested, [
      productUrl(128, b64: b64Product1),
      productUrl(128, b64: b64Product2),
      'http://localhost:13001/unsigned/rs:fit:128:0/q:50/$b64Product2.webp',
    ]);
  });

  testWidgets('a new CDN that asks for other URLs chooses again', (
    tester,
  ) async {
    final fakes = FakeImages(image: testImage);
    Widget app(ImageCdn cdn) => ProviderScope(
      overrides: [imageCdnProvider.overrideWithValue(fakes.cdn(cdn))],
      child: const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: ResponsiveImage('products/3.jpg', width: 40),
        ),
      ),
    );
    await tester.pumpWidget(app(emgr));
    await tester.pumpWidget(app(emgr.copyWith(format: ImageFormat.jpeg)));
    expect(fakes.requested, [
      productUrl(128),
      'http://localhost:13001/unsigned/rs:fit:128:0/$b64Product3.jpg',
    ]);
  });

  testWidgets('a box with no width chooses nothing and fetches nothing', (
    tester,
  ) async {
    final fakes = FakeImages(image: testImage);
    await tester.pumpWidget(
      imageApp(
        fakes,
        const ResponsiveImage(
          'products/3.jpg',
          width: 0,
          height: 10,
          placeholder: testPlaceholder,
        ),
      ),
    );
    expect(fakes.requested, isEmpty);
    expect(placeholder, findsOneWidget);
  });

  testWidgets(
    '(h) an unconfigured app fetches a path as it is and says so once',
    (tester) async {
      final printed = <String>[];
      final saved = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      final fakes = FakeImages(image: testImage);
      try {
        await tester.pumpWidget(
          imageApp(
            fakes,
            const Column(
              children: [
                ResponsiveImage('products/1.jpg', width: 40),
                ResponsiveImage('products/2.jpg', width: 40),
              ],
            ),
            cdn: const ImageCdn(),
          ),
        );
      } finally {
        debugPrint = saved;
      }
      expect(fakes.requested, ['products/1.jpg', 'products/2.jpg']);
      expect(printed, [
        'fespalier_image: "products/1.jpg" is not a URL and no image CDN is configured, '
            'so it is fetched as it is. Override imageCdnProvider in startup() '
            '(docs/responsive-images.md, "Images").',
      ]);
    },
  );

  testWidgets('a URL needs no CDN and says nothing', (tester) async {
    final printed = <String>[];
    final saved = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    final fakes = FakeImages(image: testImage);
    try {
      await tester.pumpWidget(
        imageApp(
          fakes,
          const ResponsiveImage('https://images.example.com/a.jpg', width: 40),
          cdn: const ImageCdn(),
        ),
      );
    } finally {
      debugPrint = saved;
    }
    expect(fakes.requested, ['https://images.example.com/a.jpg']);
    expect(printed, isEmpty);
  });

  testWidgets('(i) a builder error is reported once and the error view shows', (
    tester,
  ) async {
    final fakes = FakeImages(image: testImage);
    await tester.pumpWidget(
      imageApp(
        fakes,
        const ResponsiveImage(
          'products/3.jpg',
          width: 40,
          builder: TemplateUrlBuilder('{nope}'),
        ),
      ),
    );
    final error = tester.takeException();
    expect(error, isA<ImageUrlError>());
    expect(
      error.toString(),
      'TemplateUrlBuilder: unknown placeholder {nope} in "{nope}"; the placeholders are '
      '{source}, {width}, {height}, {quality} and {format}',
    );
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(fakes.requested, isEmpty);
    // A rebuild reports nothing more.
    await tester.pumpWidget(
      imageApp(
        fakes,
        const ResponsiveImage(
          'products/3.jpg',
          width: 40,
          builder: TemplateUrlBuilder('{nope}'),
          fit: BoxFit.fill,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'M2 prints as an exception of fespalier_image while building the URL',
    (tester) async {
      final details = <FlutterErrorDetails>[];
      final saved = FlutterError.onError;
      FlutterError.onError = details.add;
      try {
        await tester.pumpWidget(
          imageApp(
            FakeImages(),
            const ResponsiveImage(
              'products/3.jpg',
              width: 40,
              builder: TemplateUrlBuilder('{nope}'),
            ),
          ),
        );
      } finally {
        FlutterError.onError = saved;
      }
      expect(details, hasLength(1));
      expect(details.single.library, 'fespalier_image');
      expect(
        details.single.context.toString(),
        'while building the URL of the image "products/3.jpg"',
      );
      // The console report wraps its lines.
      final printed = details.single.toString().replaceAll(RegExp(r'\s+'), ' ');
      expect(printed, contains('EXCEPTION CAUGHT BY FESPALIER_IMAGE'));
      expect(
        printed,
        contains(
          'The following ImageUrlError was thrown while building the URL of the image '
          '"products/3.jpg":',
        ),
      );
    },
  );

  testWidgets(
    '(j) a width and a height need no measuring inside IntrinsicHeight',
    (tester) async {
      final fakes = FakeImages(image: testImage);
      await tester.pumpWidget(
        imageApp(
          fakes,
          const IntrinsicHeight(
            child: IntrinsicWidth(
              child: ResponsiveImage('products/3.jpg', width: 40, height: 40),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(fakes.requested, [productUrl(128, height: 128)]);
    },
  );

  testWidgets('(k) semantics reach the Image', (tester) async {
    final fakes = FakeImages(image: testImage);
    await tester.pumpWidget(
      imageApp(
        fakes,
        const Column(
          children: [
            ResponsiveImage(
              'products/1.jpg',
              width: 40,
              semanticLabel: 'A kettle',
            ),
            ResponsiveImage(
              'products/2.jpg',
              width: 40,
              excludeFromSemantics: true,
            ),
          ],
        ),
      ),
    );
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images[0].semanticLabel, 'A kettle');
    expect(images[0].excludeFromSemantics, isFalse);
    expect(images[1].excludeFromSemantics, isTrue);
  });

  testWidgets('an unbounded side collapses instead of throwing', (
    tester,
  ) async {
    final fakes = FakeImages(image: testImage);
    await tester.pumpWidget(
      imageApp(
        fakes,
        const Row(
          children: [ResponsiveImage('products/3.jpg', aspectRatio: 1)],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    // Unbounded width, 600 high at 1:1: 600 logical, 1800 physical.
    expect(fakes.requested, [productUrl(1920, height: 1920)]);
  });

  testWidgets('a nested ProviderScope can use another CDN', (tester) async {
    final outer = FakeImages(image: testImage);
    final inner = FakeImages(image: testImage);
    await tester.pumpWidget(
      imageApp(
        outer,
        ProviderScope(
          overrides: [
            imageCdnProvider.overrideWithValue(
              inner.cdn(emgr.copyWith(format: ImageFormat.png)),
            ),
          ],
          child: const ResponsiveImage('products/3.jpg', width: 40),
        ),
      ),
    );
    expect(outer.requested, isEmpty);
    expect(inner.requested, [
      'http://localhost:13001/unsigned/rs:fit:128:0/$b64Product3.png',
    ]);
  });

  group('fadeIn', () {
    testWidgets(
      'a load that arrives later fades in over the placeholder, then stands alone',
      (tester) async {
        final fakes = FakeImages();
        await tester.pumpWidget(
          imageApp(
            fakes,
            const ResponsiveImage(
              'products/3.jpg',
              width: 40,
              fadeIn: Duration(milliseconds: 200),
              placeholder: testPlaceholder,
            ),
          ),
        );
        fakes.complete(productUrl(128), testImage);
        await tester.pump();
        expect(find.byType(FadeTransition), findsWidgets);
        expect(placeholder, findsOneWidget);
        await tester.pump(const Duration(milliseconds: 100));
        expect(placeholder, findsOneWidget);
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump();
        expect(placeholder, findsNothing);
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      },
    );

    testWidgets('a load that was ready at once does not fade', (tester) async {
      final fakes = FakeImages(image: testImage);
      await tester.pumpWidget(
        imageApp(
          fakes,
          const ResponsiveImage(
            'products/3.jpg',
            width: 40,
            fadeIn: Duration(milliseconds: 200),
            placeholder: testPlaceholder,
          ),
        ),
      );
      expect(placeholder, findsNothing);
      expect(
        find.descendant(
          of: find.byType(ResponsiveImage),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
    });
  });
}
