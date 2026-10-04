import 'package:fespalier_image/fespalier_image.dart';
import 'package:flutter_test/flutter_test.dart';

/// `https://images.example.com/photo.jpg`, and its URL-safe base64 without padding.
const p = 'https://images.example.com/photo.jpg';
const b64p = 'aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcGhvdG8uanBn';

Matcher imageUrlError(String message) => throwsA(
  isA<ImageUrlError>().having((e) => e.toString(), 'message', message),
);

void main() {
  group('imgproxy', () {
    const builder = ImgproxyUrlBuilder(
      baseUrl: 'https://imgproxy.example.com/',
    );

    test('I1: a fill with a height, base64, webp', () {
      expect(
        builder.url(const ImageRequest(p, width: 640, height: 640)),
        'https://imgproxy.example.com/insecure/rs:fill:640:640/$b64p.webp',
      );
    });

    test('I2: plain source, fit without a height, png', () {
      expect(
        const ImgproxyUrlBuilder(
          baseUrl: 'https://imgproxy.example.com/',
          encoding: ImgproxySourceEncoding.plain,
        ).url(const ImageRequest(p, width: 640, format: ImageFormat.png)),
        'https://imgproxy.example.com/insecure/rs:fit:640:0/plain/'
        'https%3A%2F%2Fimages.example.com%2Fphoto.jpg@png',
      );
    });

    test('I3: auto has no extension', () {
      expect(
        builder.url(
          const ImageRequest(p, width: 640, format: ImageFormat.auto),
        ),
        'https://imgproxy.example.com/insecure/rs:fit:640:0/$b64p',
      );
    });

    test('I4: quality and extra options follow the resize', () {
      expect(
        builder.url(
          const ImageRequest(
            p,
            width: 256,
            height: 256,
            quality: 75,
            extra: ['bl:2', 'sh:0.5'],
          ),
        ),
        'https://imgproxy.example.com/insecure/rs:fill:256:256/q:75/bl:2/sh:0.5/'
        '$b64p.webp',
      );
    });

    test('a fit with a height is rs:fit', () {
      expect(
        builder.url(
          const ImageRequest(
            p,
            width: 200,
            height: 100,
            resize: ImageResize.fit,
          ),
        ),
        'https://imgproxy.example.com/insecure/rs:fit:200:100/$b64p.webp',
      );
    });

    test('an auto plain source on imgproxy has no extension either', () {
      expect(
        const ImgproxyUrlBuilder(
          baseUrl: 'https://imgproxy.example.com',
          encoding: ImgproxySourceEncoding.plain,
        ).url(const ImageRequest(p, width: 64, format: ImageFormat.auto)),
        'https://imgproxy.example.com/insecure/rs:fit:64:0/plain/'
        'https%3A%2F%2Fimages.example.com%2Fphoto.jpg',
      );
    });

    test('a source with a scheme ignores sourceBase', () {
      expect(
        const ImgproxyUrlBuilder(
          baseUrl: 'https://imgproxy.example.com',
          sourceBase: 'https://other.example.com/',
        ).url(const ImageRequest(p, width: 32)),
        'https://imgproxy.example.com/insecure/rs:fit:32:0/$b64p.webp',
      );
    });

    test(
      'the signer gets the path, leading slash included, and its answer replaces insecure',
      () {
        final seen = <String>[];
        final signed = ImgproxyUrlBuilder(
          baseUrl: 'https://imgproxy.example.com',
          signer: (path) {
            seen.add(path);
            return 'SIG';
          },
        );
        expect(
          signed.url(const ImageRequest(p, width: 32)),
          'https://imgproxy.example.com/SIG/rs:fit:32:0/$b64p.webp',
        );
        expect(seen, ['/rs:fit:32:0/$b64p.webp']);
      },
    );

    test('names', () {
      expect(builder.name, 'imgproxy');
      expect(builder.resizes, isTrue);
      expect(builder.widthsOf('x'), isNull);
    });

    test('M3: a base URL that is not absolute http(s)', () {
      for (final base in [
        '',
        'img.example.com',
        'ftp://img.example.com',
        '/img',
      ]) {
        expect(
          () => ImgproxyUrlBuilder(
            baseUrl: base,
          ).url(const ImageRequest(p, width: 32)),
          imageUrlError(
            'ImgproxyUrlBuilder: baseUrl "$base" is not an absolute http or https URL',
          ),
        );
      }
    });

    test('const builders with the same fields are equal', () {
      expect(
        const ImgproxyUrlBuilder(baseUrl: 'https://a.example'),
        const ImgproxyUrlBuilder(baseUrl: 'https://a.example'),
      );
      expect(
        const ImgproxyUrlBuilder(baseUrl: 'https://a.example').hashCode,
        const ImgproxyUrlBuilder(baseUrl: 'https://a.example').hashCode,
      );
      expect(
        const ImgproxyUrlBuilder(baseUrl: 'https://a.example'),
        isNot(const ImgproxyUrlBuilder.emgr(baseUrl: 'https://a.example')),
      );
    });
  });

  group('EmgR', () {
    test('E3: a source base, fit, webp, unsigned', () {
      expect(
        const ImgproxyUrlBuilder.emgr(
          baseUrl: 'http://localhost:13001',
          sourceBase: 'https://images.example.com/',
        ).url(const ImageRequest('photo.jpg', width: 1080)),
        'http://localhost:13001/unsigned/rs:fit:1080:0/$b64p.webp',
      );
    });

    test('E4: a plain source takes its extension after a dot', () {
      expect(
        const ImgproxyUrlBuilder.emgr(
          baseUrl: 'http://localhost:13001',
          encoding: ImgproxySourceEncoding.plain,
        ).url(const ImageRequest(p, width: 640, format: ImageFormat.png)),
        'http://localhost:13001/unsigned/rs:fit:640:0/plain/'
        'https%3A%2F%2Fimages.example.com%2Fphoto.jpg.png',
      );
    });

    test('E5: auto is the .auto extension', () {
      expect(
        const ImgproxyUrlBuilder.emgr(
          baseUrl: 'http://localhost:13001',
        ).url(const ImageRequest(p, width: 640, format: ImageFormat.auto)),
        'http://localhost:13001/unsigned/rs:fit:640:0/$b64p.auto',
      );
    });

    test('E6: presets only', () {
      final builder = ImgproxyUrlBuilder.emgr(
        baseUrl: 'http://localhost:13001',
        processing: (r) => ['pr:w${r.width}'],
      );
      expect(
        builder.url(const ImageRequest(p, width: 640)),
        'http://localhost:13001/unsigned/pr:w640/$b64p.webp',
      );
    });

    test('the plain auto source is .auto', () {
      expect(
        const ImgproxyUrlBuilder.emgr(
          baseUrl: 'http://localhost:13001',
          encoding: ImgproxySourceEncoding.plain,
        ).url(const ImageRequest(p, width: 64, format: ImageFormat.auto)),
        'http://localhost:13001/unsigned/rs:fit:64:0/plain/'
        'https%3A%2F%2Fimages.example.com%2Fphoto.jpg.auto',
      );
    });

    test('names', () {
      expect(
        const ImgproxyUrlBuilder.emgr(baseUrl: 'http://x.example').name,
        'emgr',
      );
    });
  });

  group('Cloudinary', () {
    const builder = CloudinaryUrlBuilder(cloudName: 'demo');

    test('C1: fill, a public id with a slash gets v1', () {
      expect(
        builder.url(
          const ImageRequest('docs/shoes.jpg', width: 640, height: 480),
        ),
        'https://res.cloudinary.com/demo/image/upload/'
        'c_fill,f_webp,h_480,q_auto,w_640/v1/docs/shoes.jpg',
      );
    });

    test('C2: limit without a height, no slash, no version', () {
      expect(
        builder.url(const ImageRequest('sample.jpg', width: 1080)),
        'https://res.cloudinary.com/demo/image/upload/c_limit,f_webp,q_auto,w_1080/sample.jpg',
      );
    });

    test('C3: fetch with a quality and jpeg', () {
      expect(
        const CloudinaryUrlBuilder(
          cloudName: 'demo',
          delivery: CloudinaryDelivery.fetch,
        ).url(
          const ImageRequest(
            p,
            width: 256,
            height: 256,
            quality: 80,
            format: ImageFormat.jpeg,
          ),
        ),
        'https://res.cloudinary.com/demo/image/fetch/'
        'c_fill,f_jpg,h_256,q_80,w_256/https://images.example.com/photo.jpg',
      );
    });

    test('C4: a fetched URL has its query escaped', () {
      expect(
        const CloudinaryUrlBuilder(
          cloudName: 'demo',
          delivery: CloudinaryDelivery.fetch,
        ).url(
          const ImageRequest(
            'https://images.example.com/p.jpg?v=2',
            width: 640,
          ),
        ),
        'https://res.cloudinary.com/demo/image/fetch/'
        'c_limit,f_webp,q_auto,w_640/https://images.example.com/p.jpg%3Fv=2',
      );
    });

    test('C5: auto and an extra component', () {
      expect(
        builder.url(
          const ImageRequest(
            'docs/shoes.jpg',
            width: 640,
            height: 480,
            format: ImageFormat.auto,
            extra: ['e_grayscale'],
          ),
        ),
        'https://res.cloudinary.com/demo/image/upload/'
        'c_fill,f_auto,h_480,q_auto,w_640/e_grayscale/v1/docs/shoes.jpg',
      );
    });

    test('C6: a version is kept', () {
      expect(
        builder.url(const ImageRequest('v1712/docs/shoes.jpg', width: 640)),
        'https://res.cloudinary.com/demo/image/upload/'
        'c_limit,f_webp,q_auto,w_640/v1712/docs/shoes.jpg',
      );
    });

    test('forceVersion off, a CNAME base and fit with a height', () {
      expect(
        const CloudinaryUrlBuilder(
          cloudName: 'demo',
          baseUrl: 'https://images.example.com/',
          forceVersion: false,
        ).url(
          const ImageRequest(
            'docs/shoes.jpg',
            width: 640,
            height: 480,
            resize: ImageResize.fit,
          ),
        ),
        'https://images.example.com/demo/image/upload/'
        'c_limit,f_webp,h_480,q_auto,w_640/docs/shoes.jpg',
      );
    });

    test(
      'a fetched URL with non-ASCII bytes and a percent sign is escaped per byte',
      () {
        expect(
          const CloudinaryUrlBuilder(
            cloudName: 'demo',
            delivery: CloudinaryDelivery.fetch,
          ).url(
            const ImageRequest('https://x.example/ü 100%.jpg#a[1]', width: 32),
          ),
          'https://res.cloudinary.com/demo/image/fetch/c_limit,f_webp,q_auto,w_32/'
          'https://x.example/%C3%BC%20100%25.jpg%23a%5B1%5D',
        );
      },
    );

    test('M3 and M4', () {
      expect(
        () => const CloudinaryUrlBuilder(
          cloudName: 'demo',
          baseUrl: 'res.cloudinary.com',
        ).url(const ImageRequest('a', width: 1)),
        imageUrlError(
          'CloudinaryUrlBuilder: baseUrl "res.cloudinary.com" is not an absolute http or https URL',
        ),
      );
      for (final name in ['', 'a/b', 'https://res.cloudinary.com/demo']) {
        expect(
          () => CloudinaryUrlBuilder(
            cloudName: name,
          ).url(const ImageRequest('a', width: 1)),
          imageUrlError(
            'CloudinaryUrlBuilder: cloudName "$name" must be a cloud name, like "demo", not a URL or a path',
          ),
        );
      }
    });

    test('names', () {
      expect(builder.name, 'cloudinary');
      expect(builder, const CloudinaryUrlBuilder(cloudName: 'demo'));
    });
  });

  group('imgix', () {
    const builder = ImgixUrlBuilder(domain: 'demos.imgix.net');

    test('X1: crop with a height', () {
      expect(
        builder.url(const ImageRequest('bridge.png', width: 640, height: 480)),
        'https://demos.imgix.net/bridge.png?fit=crop&fm=webp&h=480&w=640',
      );
    });

    test('X2: spaces in the path, quality, auto format', () {
      expect(
        builder.url(
          const ImageRequest(
            'products/1 copy.jpg',
            width: 1080,
            quality: 60,
            format: ImageFormat.auto,
          ),
        ),
        'https://demos.imgix.net/products/1%20copy.jpg?auto=format&fit=max&q=60&w=1080',
      );
    });

    test('X4: a web-proxy source is one encoded segment', () {
      expect(
        builder.url(const ImageRequest(p, width: 384)),
        'https://demos.imgix.net/https%3A%2F%2Fimages.example.com%2Fphoto.jpg?fit=max&fm=webp&w=384',
      );
    });

    test('X5: extras are sorted in and replace a built-in key', () {
      expect(
        builder.url(
          const ImageRequest(
            'bridge.png',
            width: 640,
            height: 480,
            extra: ['crop=faces', 'sat=-100'],
          ),
        ),
        'https://demos.imgix.net/bridge.png?crop=faces&fit=crop&fm=webp&h=480&sat=-100&w=640',
      );
      expect(
        builder.url(
          const ImageRequest('bridge.png', width: 640, extra: ['fit=clip']),
        ),
        'https://demos.imgix.net/bridge.png?fit=clip&fm=webp&w=640',
      );
    });

    test('http, and a leading slash is dropped', () {
      expect(
        const ImgixUrlBuilder(
          domain: 'demos.imgix.net',
          https: false,
        ).url(const ImageRequest('/a/b.png', width: 32)),
        'http://demos.imgix.net/a/b.png?fit=max&fm=webp&w=32',
      );
    });

    test('the signer gets path?query and its answer becomes s', () {
      final seen = <String>[];
      final signed = ImgixUrlBuilder(
        domain: 'demos.imgix.net',
        signer: (payload) {
          seen.add(payload);
          return 'SIG';
        },
      );
      expect(
        signed.url(const ImageRequest('bridge.png', width: 32)),
        'https://demos.imgix.net/bridge.png?fit=max&fm=webp&w=32&s=SIG',
      );
      expect(seen, ['/bridge.png?fit=max&fm=webp&w=32']);
    });

    test('M5 and M6', () {
      for (final domain in [
        '',
        'https://demos.imgix.net',
        'demos.imgix.net/x',
        'a:80',
      ]) {
        expect(
          () => ImgixUrlBuilder(
            domain: domain,
          ).url(const ImageRequest('a', width: 1)),
          imageUrlError(
            'ImgixUrlBuilder: domain "$domain" must be a host name, like "demo.imgix.net", without a scheme or a path',
          ),
        );
      }
      expect(
        () => builder.url(const ImageRequest('a', width: 1, extra: ['sat'])),
        imageUrlError(
          'ImgixUrlBuilder: extra option "sat" is not key=value, like "sat=-100"',
        ),
      );
    });

    test('names', () {
      expect(builder.name, 'imgix');
      expect(builder, const ImgixUrlBuilder(domain: 'demos.imgix.net'));
    });
  });

  group('Thumbor', () {
    const builder = ThumborUrlBuilder(baseUrl: 'https://thumbor.example.com');

    test('T2: the format filter and a crop', () {
      expect(
        builder.url(
          const ImageRequest(
            'images.example.com/photo.jpg',
            width: 640,
            height: 480,
          ),
        ),
        'https://thumbor.example.com/unsafe/640x480/filters:format(webp)/images.example.com/photo.jpg',
      );
    });

    test('T3: quality, jpeg and a trailing slash on the base', () {
      expect(
        const ThumborUrlBuilder(baseUrl: 'https://thumbor.example.com/').url(
          const ImageRequest(
            'images.example.com/photo.jpg',
            width: 1080,
            quality: 80,
            format: ImageFormat.jpeg,
          ),
        ),
        'https://thumbor.example.com/unsafe/1080x0/filters:quality(80):format(jpeg)/images.example.com/photo.jpg',
      );
    });

    test('T4: fit-in, smart and an extra filter', () {
      expect(
        const ThumborUrlBuilder(
          baseUrl: 'https://thumbor.example.com',
          smart: true,
        ).url(
          const ImageRequest(
            'images.example.com/photo.jpg',
            width: 640,
            height: 640,
            resize: ImageResize.fit,
            extra: ['grayscale()'],
          ),
        ),
        'https://thumbor.example.com/unsafe/fit-in/640x640/smart/filters:format(webp):grayscale()/images.example.com/photo.jpg',
      );
    });

    test('auto has no format filter, so no filters segment', () {
      expect(
        builder.url(
          const ImageRequest(
            'images.example.com/photo.jpg',
            width: 300,
            height: 200,
            format: ImageFormat.auto,
          ),
        ),
        'https://thumbor.example.com/unsafe/300x200/images.example.com/photo.jpg',
      );
    });

    test('png and avif filters', () {
      expect(
        builder.url(
          const ImageRequest('a.jpg', width: 32, format: ImageFormat.png),
        ),
        'https://thumbor.example.com/unsafe/32x0/filters:format(png)/a.jpg',
      );
      expect(
        builder.url(
          const ImageRequest('a.jpg', width: 32, format: ImageFormat.avif),
        ),
        'https://thumbor.example.com/unsafe/32x0/filters:format(avif)/a.jpg',
      );
    });

    test('M3 and names', () {
      expect(
        () => const ThumborUrlBuilder(
          baseUrl: 'thumbor.example.com',
        ).url(const ImageRequest('a', width: 1)),
        imageUrlError(
          'ThumborUrlBuilder: baseUrl "thumbor.example.com" is not an absolute http or https URL',
        ),
      );
      expect(builder.name, 'thumbor');
    });
  });

  group('template', () {
    const builder = TemplateUrlBuilder(
      'https://cdn.example.com/{source}?w={width}&h={height}&q={quality}&fm={format}',
    );

    test('every placeholder', () {
      expect(
        builder.url(const ImageRequest('products/1.jpg', width: 640)),
        'https://cdn.example.com/products/1.jpg?w=640&h=0&q=80&fm=webp',
      );
      expect(
        builder.url(
          const ImageRequest(
            'products/1.jpg',
            width: 640,
            height: 480,
            quality: 50,
            format: ImageFormat.jpeg,
          ),
        ),
        'https://cdn.example.com/products/1.jpg?w=640&h=480&q=50&fm=jpg',
      );
    });

    test('the default quality and the name are the constructor\'s', () {
      const b = TemplateUrlBuilder(
        '{source}/{quality}',
        quality: 70,
        name: 'mine',
      );
      expect(b.url(const ImageRequest('a', width: 1)), 'a/70');
      expect(b.name, 'mine');
      expect(builder.name, 'template');
    });

    test('resizes only with {width}', () {
      expect(builder.resizes, isTrue);
      expect(
        const TemplateUrlBuilder('https://cdn.example.com/{source}').resizes,
        isFalse,
      );
    });

    test('M7: an unknown placeholder', () {
      expect(
        () => const TemplateUrlBuilder(
          'https://x.example/{nope}',
        ).url(const ImageRequest('a', width: 1)),
        imageUrlError(
          'TemplateUrlBuilder: unknown placeholder {nope} in "https://x.example/{nope}"; '
          'the placeholders are {source}, {width}, {height}, {quality} and {format}',
        ),
      );
    });

    test('equality', () {
      expect(const TemplateUrlBuilder('a'), const TemplateUrlBuilder('a'));
      expect(
        const TemplateUrlBuilder('a'),
        isNot(const TemplateUrlBuilder('b')),
      );
    });
  });

  group('srcset', () {
    const builder = SrcsetUrlBuilder();
    const srcset =
        'https://a.example/p-256.webp 256w, https://a.example/p-640.webp 640w,'
        'https://a.example/p-1080.webp 1080w';

    test('parse', () {
      expect(SrcsetUrlBuilder.parse(srcset), {
        256: 'https://a.example/p-256.webp',
        640: 'https://a.example/p-640.webp',
        1080: 'https://a.example/p-1080.webp',
      });
    });

    test(
      'a comma inside a URL stays, and a repeated width keeps the first',
      () {
        expect(SrcsetUrlBuilder.parse('https://x/a,b.jpg 100w'), {
          100: 'https://x/a,b.jpg',
        });
        expect(SrcsetUrlBuilder.parse('a 100w, b 100w'), {100: 'a'});
        expect(SrcsetUrlBuilder.parse('\n a 100w ,\n b 200w \n'), {
          100: 'a',
          200: 'b',
        });
      },
    );

    test('of writes the widths in increasing order', () {
      expect(SrcsetUrlBuilder.of({640: 'b', 256: 'a'}), 'a 256w, b 640w');
      expect(
        SrcsetUrlBuilder.parse(SrcsetUrlBuilder.of({640: 'b', 256: 'a'})),
        {256: 'a', 640: 'b'},
      );
    });

    test('widthsOf and url', () {
      expect(builder.widthsOf(srcset), [256, 640, 1080]);
      expect(
        builder.url(const ImageRequest(srcset, width: 640)),
        'https://a.example/p-640.webp',
      );
      // Not an exact width: the smallest wider one, else the widest.
      expect(
        builder.url(const ImageRequest(srcset, width: 300)),
        'https://a.example/p-640.webp',
      );
      expect(
        builder.url(const ImageRequest(srcset, width: 5000)),
        'https://a.example/p-1080.webp',
      );
    });

    test('M8: empty', () {
      for (final empty in ['', '  ', ' , ,']) {
        expect(
          () => SrcsetUrlBuilder.parse(empty),
          imageUrlError('SrcsetUrlBuilder: the srcset is empty'),
        );
      }
    });

    test('M9: a candidate without a width descriptor', () {
      for (final (bad, shown) in [
        ('https://a.example/p.webp', 'https://a.example/p.webp'),
        ('https://a.example/p.webp 2x', 'https://a.example/p.webp 2x'),
        ('https://a.example/p.webp,', 'https://a.example/p.webp'),
        ('https://a.example/p.webp 0w', 'https://a.example/p.webp 0w'),
        ('https://a.example/p.webp 100h', 'https://a.example/p.webp 100h'),
      ]) {
        expect(
          () => SrcsetUrlBuilder.parse(bad),
          imageUrlError(
            'SrcsetUrlBuilder: "$shown" in the srcset has no width descriptor, like "photo-640.webp 640w"',
          ),
          reason: bad,
        );
      }
    });

    test('names', () {
      expect(builder.name, 'srcset');
      expect(builder.resizes, isTrue);
      expect(builder, const SrcsetUrlBuilder());
    });
  });

  group('direct', () {
    test('the source, undecoded by the CDN', () {
      const builder = DirectUrlBuilder();
      expect(builder.url(const ImageRequest(p, width: 64)), p);
      expect(builder.name, 'direct');
      expect(builder.resizes, isFalse);
      expect(builder.widthsOf(p), isNull);
      expect(builder, const DirectUrlBuilder());
    });
  });

  group('formats', () {
    test('extensions', () {
      expect(
        {for (final f in ImageFormat.values) f: f.extension},
        {
          ImageFormat.webp: 'webp',
          ImageFormat.jpeg: 'jpg',
          ImageFormat.png: 'png',
          ImageFormat.avif: 'avif',
          ImageFormat.auto: 'auto',
        },
      );
    });
  });
}
