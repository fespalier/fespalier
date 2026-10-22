# fespalier_image

Network images sized by their layout, for [fespalier](https://github.com/fespalier/fespalier) apps (since
0.9.0). A `ResponsiveImage` measures its box, multiplies by the device pixel ratio, rounds up to one of a few
widths and asks the app's image CDN for that one: imgproxy and EmgR, Cloudinary, imgix, Thumbor, a URL
template, or a srcset that the backend signed. It wraps no image package and no CDN SDK.

The docs cover all of it: [Images](https://github.com/fespalier/fespalier/blob/main/docs/responsive-images.md) (the CDN, the
buckets, the widget, each builder, signing, heroes, the web, caching, testing, what it costs). This page is
the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if
they are the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.21.1
  fespalier_image:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_image
      ref: v0.21.1
```

<!-- x-release-please-end -->

There is nothing to put in `pubspec.yaml`'s `fespalier:` section and nothing to generate: `app.g.dart` is the
same bytes.

## Use it

Choose the CDN once, in `startup()`:

```dart
// lib/app/startup.dart
Future<List<Override>> startup() async => [
  imageCdnProvider.overrideWithValue(
    ImageCdn(
      transport: transport, // the app's HttpTransport chain (fespalier_transport)
      builder: const ImgproxyUrlBuilder.emgr(
        baseUrl: 'https://img.example.com',
        sourceBase: 'https://images.example.com/',
      ),
    ),
  ),
];
```

Images load through `ImageCdn.transport` (since 0.21.0): a `TransportImage`, which is `NetworkImage` over your
`HttpTransport` chain (so its requests are signed and traced like the others), decoded with the image cache's own
decoder and reporting a bad status as `NetworkImageLoadException`. A CDN with neither `transport` nor `providerFactory`
reports an `ImageUrlError`. `providerFactory` stays the escape hatch for a disk cache or a plain `NetworkImage`.
**On the web a transport fetch needs CORS** on the image host, which `NetworkImage`'s `<img>` fallback did not: for a
host that sends none, pass `providerFactory: (url) => NetworkImage(url, webHtmlElementStrategy:
WebHtmlElementStrategy.fallback)` (the field `webHtmlElementStrategy` of `ImageCdn` is gone).

Then show an image at the size its layout gives it. Say the shape with `aspectRatio`, so the server crops and
the CDN caches one URL per bucket and not one per pixel of padding:

```dart
ResponsiveImage('products/3.jpg', width: 160, aspectRatio: 1)
```

## No key in the app

The package has no parameter for a signing key or a salt and ships no HMAC code, on purpose: a key in an app
binary or in `main.dart.js` is public, `--dart-define` included, and turns your resizer into an open image
proxy. Let the backend return signed URLs as a srcset (`SrcsetUrlBuilder`), or run the server unsigned with its
source and option allowlists and presets only, or give a builder a `signer:` that looks signatures up. The
docs' [Signed image URLs](https://github.com/fespalier/fespalier/blob/main/docs/responsive-images.md#signed-image-urls) has the three ways.

## Tests

`package:fespalier_image/testing.dart` has `FakeImages`: a `providerFactory` whose loads record their URL and
complete when the test says or at once, with no network. `imageCdnProvider.overrideWithValue(fakes.cdn(yourCdn))`
in `pumpRouter(overrides:)` asserts the exact URLs of your real builder.
