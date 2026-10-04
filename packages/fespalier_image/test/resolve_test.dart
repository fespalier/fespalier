import 'package:fespalier_image/fespalier_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const base = 'http://localhost:13001/unsigned';
const p3 = 'aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcHJvZHVjdHMvMy5qcGc';

const cdn = ImageCdn(
  builder: ImgproxyUrlBuilder.emgr(
    baseUrl: 'http://localhost:13001',
    sourceBase: 'https://images.example.com/',
  ),
);

void main() {
  group('resolve', () {
    for (final (logical, dpr, ratio, options) in [
      (40.0, 3.0, 1.0, 'rs:fill:128:128'),
      (160.0, 3.0, 1.0, 'rs:fill:640:640'),
      (360.0, 3.0, 16 / 9, 'rs:fill:1080:608'),
      (411.42857142857144, 2.625, null, 'rs:fit:1080:0'),
      (400.0, 4.0, null, 'rs:fit:1200:0'),
      (800.0, 3.0, 1.0, 'rs:fill:3840:3840'),
    ]) {
      test('$logical logical at $dpr, ratio $ratio is $options', () {
        final resolved = cdn.resolve(
          'products/3.jpg',
          logicalWidth: logical,
          devicePixelRatio: dpr,
          aspectRatio: ratio,
        );
        expect(resolved, isNotNull);
        expect(resolved!.url, '$base/$options/$p3.webp');
      });
    }

    test('a box with no width fetches nothing', () {
      expect(
        cdn.resolve('products/3.jpg', logicalWidth: 0, devicePixelRatio: 3),
        isNull,
      );
      expect(
        cdn.resolve(
          'products/3.jpg',
          logicalWidth: double.infinity,
          devicePixelRatio: 3,
        ),
        isNull,
      );
    });

    test('the resolved request says what was asked', () {
      final resolved = cdn.resolve(
        'products/3.jpg',
        logicalWidth: 160,
        devicePixelRatio: 3,
        aspectRatio: 1,
        quality: 70,
        format: ImageFormat.jpeg,
        extra: const ['bl:2'],
      )!;
      expect(
        resolved.request,
        const ImageRequest(
          'products/3.jpg',
          width: 640,
          height: 640,
          quality: 70,
          format: ImageFormat.jpeg,
          extra: ['bl:2'],
        ),
      );
      expect(resolved.builder, cdn.builder);
    });

    test('the CDN\'s quality and format are the defaults, the call\'s win', () {
      final configured = cdn.copyWith(quality: 60, format: ImageFormat.png);
      expect(
        configured
            .resolve('a.jpg', logicalWidth: 40, devicePixelRatio: 3)!
            .request,
        const ImageRequest(
          'a.jpg',
          width: 128,
          quality: 60,
          format: ImageFormat.png,
        ),
      );
      expect(
        configured
            .resolve(
              'a.jpg',
              logicalWidth: 40,
              devicePixelRatio: 3,
              quality: 90,
              format: ImageFormat.avif,
            )!
            .request,
        const ImageRequest(
          'a.jpg',
          width: 128,
          quality: 90,
          format: ImageFormat.avif,
        ),
      );
    });

    test('a builder and buckets of the call replace the CDN\'s', () {
      final resolved = cdn.resolve(
        'p.jpg',
        logicalWidth: 100,
        devicePixelRatio: 1,
        builder: const TemplateUrlBuilder(
          'https://c.example/{source}?w={width}',
        ),
        buckets: const ImageBuckets([50, 100, 200]),
      )!;
      expect(resolved.url, 'https://c.example/p.jpg?w=100');
    });

    test('a srcset\'s widths replace the buckets', () {
      const sizes = ImageCdn(builder: SrcsetUrlBuilder());
      const srcset =
          'https://a.example/p-256.webp 256w, https://a.example/p-640.webp 640w, '
          'https://a.example/p-1080.webp 1080w';
      expect(
        sizes.resolve(srcset, logicalWidth: 100, devicePixelRatio: 3)!.url,
        'https://a.example/p-640.webp',
      );
      expect(
        sizes.resolve(srcset, logicalWidth: 400, devicePixelRatio: 3)!.url,
        'https://a.example/p-1080.webp',
      );
    });

    test('a misconfigured builder throws', () {
      expect(
        () => const ImageCdn(
          builder: TemplateUrlBuilder('{nope}'),
        ).resolve('a', logicalWidth: 10, devicePixelRatio: 1),
        throwsA(isA<ImageUrlError>()),
      );
      expect(
        () => cdn.resolve(
          'a',
          logicalWidth: 10,
          devicePixelRatio: 1,
          buckets: const ImageBuckets([]),
        ),
        throwsA(isA<ImageUrlError>()),
      );
    });
  });

  group('providerFor', () {
    ResolvedImage resolveOf(ImageCdn cdn, [ImageUrlBuilder? builder]) =>
        cdn.resolve(
          'products/3.jpg',
          logicalWidth: 40,
          devicePixelRatio: 3,
          builder: builder,
        )!;

    test(
      'a NetworkImage with the URL, never the HTML element fallback by default',
      () {
        final image = resolveOf(cdn);
        final provider = cdn.providerFor(image);
        expect(provider, isA<NetworkImage>());
        final network = provider as NetworkImage;
        expect(network.url, image.url);
        expect(network.webHtmlElementStrategy, WebHtmlElementStrategy.never);
      },
    );

    test('the CDN\'s web strategy reaches the provider', () {
      final configured = cdn.copyWith(
        webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
      );
      final provider =
          configured.providerFor(resolveOf(configured)) as NetworkImage;
      expect(provider.webHtmlElementStrategy, WebHtmlElementStrategy.fallback);
    });

    test('providerFactory\'s provider when set', () {
      final made = <String>[];
      final custom = NetworkImage('https://custom.example/x');
      final configured = cdn.copyWith(
        providerFactory: (url) {
          made.add(url);
          return custom;
        },
      );
      final image = resolveOf(configured);
      expect(configured.providerFor(image), same(custom));
      expect(made, [image.url]);
    });

    test('a builder that does not resize is decoded at the bucket width', () {
      const direct = ImageCdn();
      final image = direct.resolve(
        'https://images.example.com/photo.jpg',
        logicalWidth: 40,
        devicePixelRatio: 3,
      )!;
      final provider = direct.providerFor(image);
      expect(provider, isA<ResizeImage>());
      final resize = provider as ResizeImage;
      expect(resize.width, 128);
      expect(resize.height, isNull);
      expect(resize.policy, ResizeImagePolicy.fit);
      expect(resize.allowUpscaling, isFalse);
      expect(image.url, 'https://images.example.com/photo.jpg');
    });

    test('a resizing builder is not wrapped', () {
      expect(cdn.providerFor(resolveOf(cdn)), isNot(isA<ResizeImage>()));
    });
  });

  test('ImageCdn equality is by field', () {
    expect(const ImageCdn(), const ImageCdn());
    expect(const ImageCdn().hashCode, const ImageCdn().hashCode);
    expect(const ImageCdn(), isNot(const ImageCdn(quality: 80)));
    expect(cdn.copyWith(), cdn);
  });
}
