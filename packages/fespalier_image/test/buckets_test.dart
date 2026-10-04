import 'package:fespalier_image/fespalier_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the standard widths are Next.js 16\'s imageSizes and deviceSizes', () {
    expect(ImageBuckets.standard.widths, <int>[
      32,
      48,
      64,
      96,
      128,
      256,
      384,
      640,
      750,
      828,
      1080,
      1200,
      1920,
      2048,
      3840,
    ]);
  });

  test(
    'pick takes the smallest width that is wide enough, else the largest',
    () {
      const b = ImageBuckets.standard;
      expect(b.pick(1), 32);
      expect(b.pick(32), 32);
      expect(b.pick(33), 48);
      expect(b.pick(120), 128);
      expect(b.pick(480), 640);
      expect(b.pick(1080), 1080);
      expect(b.pick(1081), 1200);
      expect(b.pick(4000), 3840);
    },
  );

  test(
    'physical rounds up with half a pixel of tolerance and caps the ratio',
    () {
      expect(ImageBuckets.physical(40, 3), 120);
      expect(ImageBuckets.physical(411.42857142857144, 2.625), 1080);
      expect(ImageBuckets.physical(400, 4), 1200);
      expect(ImageBuckets.physical(400, 4, maxPixelRatio: 4), 1600);
      expect(ImageBuckets.physical(0, 3), 0);
      expect(ImageBuckets.physical(double.infinity, 3), 0);
      expect(ImageBuckets.physical(double.nan, 3), 0);
      expect(ImageBuckets.physical(-1, 2), 0);
      expect(ImageBuckets.physical(0.1, 1), 1);
      expect(ImageBuckets.physical(20, 1), 20);
    },
  );

  test('bad widths are M10', () {
    for (final (widths, shown) in [
      (<int>[], '[]'),
      (<int>[64, 32], '[64, 32]'),
      (<int>[32, 32], '[32, 32]'),
      (<int>[0, 32], '[0, 32]'),
    ]) {
      expect(
        () => ImageBuckets(widths).pick(10),
        throwsA(
          isA<ImageUrlError>().having(
            (e) => e.toString(),
            'message',
            'ImageBuckets: the widths must be positive and increasing, got '
                '$shown',
          ),
        ),
      );
    }
  });

  test('buckets with the same widths are equal', () {
    expect(const ImageBuckets([1, 2]), const ImageBuckets([1, 2]));
    expect(
      const ImageBuckets([1, 2]).hashCode,
      const ImageBuckets([1, 2]).hashCode,
    );
    expect(const ImageBuckets([1, 2]), isNot(const ImageBuckets([1, 3])));
    expect(
      ImageBuckets.standard,
      const ImageBuckets(<int>[
        32, 48, 64, 96, 128, 256, 384, 640, 750, 828, 1080, 1200, 1920, 2048, //
        3840,
      ]),
    );
  });

  group('ImageRequest', () {
    test('toString and equality', () {
      const a = ImageRequest('products/3.jpg', width: 640, height: 640);
      expect(
        a.toString(),
        'ImageRequest(products/3.jpg, 640x640, fill, q=null, webp)',
      );
      expect(a, const ImageRequest('products/3.jpg', width: 640, height: 640));
      expect(a, isNot(const ImageRequest('products/3.jpg', width: 640)));
      expect(
        const ImageRequest('a', width: 1, extra: ['x']),
        const ImageRequest('a', width: 1, extra: ['x']),
      );
    });

    test('a request is a variant of the same picture at another size', () {
      const a = ImageRequest('p', width: 128, height: 128);
      expect(
        a.isVariantOf(const ImageRequest('p', width: 640, height: 640)),
        isTrue,
      );
      expect(
        a.isVariantOf(const ImageRequest('p', width: 640, height: 480)),
        isFalse,
      );
      expect(a.isVariantOf(const ImageRequest('p', width: 640)), isFalse);
      expect(
        a.isVariantOf(const ImageRequest('q', width: 128, height: 128)),
        isFalse,
      );
      expect(
        a.isVariantOf(
          const ImageRequest(
            'p',
            width: 128,
            height: 128,
            format: ImageFormat.png,
          ),
        ),
        isFalse,
      );
      expect(
        const ImageRequest(
          'p',
          width: 128,
        ).isVariantOf(const ImageRequest('p', width: 640)),
        isTrue,
      );
    });

    test(
      'heights rounded to a pixel at every bucket of a 16:9 shape are one shape',
      () {
        final heights = {
          for (final w in ImageBuckets.standard.widths)
            w: (w / (16 / 9)).round(),
        };
        for (final a in heights.entries) {
          for (final b in heights.entries) {
            expect(
              ImageRequest(
                'p',
                width: a.key,
                height: a.value,
              ).isVariantOf(ImageRequest('p', width: b.key, height: b.value)),
              isTrue,
              reason: '${a.key}x${a.value} and ${b.key}x${b.value}',
            );
          }
        }
      },
    );
  });
}
