# Images with the rest of the app: precache, heroes, the web, caching, tests

Since 0.9.0. [`../SKILL.md`](../SKILL.md) has the CDN and the widget; this page is how an image meets
navigation, the web, the cache and a test.

## The widget's rules, in one place

- **The box.** `width` and `height` make a `SizedBox`; an `aspectRatio` (or both `width` and `height`) an
  `AspectRatio`; otherwise the parent decides. The image, placeholder and error view fill it, and an
  unbounded side collapses instead of throwing.
- **Measuring.** With a `width`, nothing is measured (intrinsic-safe). Else a `LayoutBuilder` reads the maximum
  width when bounded; else the maximum height × `aspectRatio`; else the view's width.
- **Choosing.** The bucket is chosen at the first layout; again from scratch when the inputs change (source,
  options, builder, buckets, a CDN that asks for other URLs); and **grow-only** when the view's size or the
  device pixel ratio changes, and, with `growWithBox: true`, when the box grows. A width of 0 chooses nothing:
  the placeholder shows and nothing is fetched. The widget builds no `Future` and no microtask of its own and
  starts no timer.
- **Showing.** An `Image` with `gaplessPlayback: true`. While it loads: the widest loaded variant of the same
  picture (same source, builder, shape, quality, format and extra), else the placeholder. A load error shows
  the error view, and `retry` evicts the provider and loads again. `fadeIn` fades in a load that arrives later.

## Precache at the size the page shows

Behind a `RouteLink` (`onPreload` is since 0.9.0), where the link starts its preload:

```dart
RouteLink(
  to: ProductRoute(id: p.id),
  preload: Preload.intent,
  // The page shows the photo pagePhotoSize wide: warm that size, not the row's.
  onPreload: (context) => ResponsiveImage.precache(context, p.image, width: pagePhotoSize, aspectRatio: 1),
  builder: (context, follow) => ListTile(title: Text(p.name), onTap: follow),
)
```

`onPreload` runs with the link's `BuildContext` right after `route.preload(ref)` started: for `Preload.intent` on
the first intent (and on the next one after a failed preload), for `Preload.visible` each time the link comes back
on screen. It is **not** called when the link preloads nothing (`Preload.none`, or a `uri:` link no
`RouteLinkScope.match` matches). It must return at once; what it throws is reported with
`FlutterError.reportError` (library `fespalier`, context `while running onPreload of a RouteLink to /products/3`)
and the preload goes on. Imperatively, call `precache` before the navigation:

```dart
await ResponsiveImage.precache(context, product.image, width: pagePhotoSize, aspectRatio: 1);
ProductRoute(id: product.id).go(context);
```

`ResponsiveImage.precache(context, source, {width, height, aspectRatio, ...})` computes the same URL a
`ResponsiveImage` of that size will ask for, with the CDN of `context` (`imageCdnProvider`, so a nested
`ProviderScope` counts), and loads it into Flutter's image cache. It completes when the image is loaded or has
failed (a failure is dropped: the widget shows its own error). Nothing to fetch (a width that is not positive)
completes at once. A misconfigured builder is reported with the context `while precaching the image "…"`.
Without a `width` it uses the view's width.

The page's size is known only where there is a `BuildContext`, not in `route.preload(ref)`. Buckets absorb a few
points of padding, and **one constant for the page's photo size, shared by the page and the precache**, makes
the two URLs equal (a precache at another bucket is a wasted download: "it loads twice").

## Heroes

`route.imageHero('photo', child: ResponsiveImage(...))` on both pages is `route.hero('photo', shuttle:
ResponsiveImage.flightShuttle, child: ...)`. The flight shuttle puts a `ResponsiveImageFlight` above the
image: an image in flight **starts no load** and shows the widest loaded variant of its source, of any shape,
else its placeholder. `Heroes(shuttle: ResponsiveImage.flightShuttle)` in the root `transition.dart` does it for
every hero.

- **With the page's size precached:** push, the shuttle shows that variant at every size of the flight, and
  the destination, built offstage from the first frame of the flight, has it in its first frame. Pop: the
  shuttle (the list's child) shows the same variant shrinking. No URL changes and no request during the flight.
- **Without a precache:** the shuttle shows the row's thumbnail (the only loaded variant); the destination
  shows that thumbnail until its own image arrives. Never blank.
- **Different shapes** (1:1 row, 4:3 page): the flight still shows the loaded variant; at rest the page shows
  its placeholder until its own shape loads, because a stand-in of another shape would jump.
- **Without the flight shuttle:** Flutter's default rebuilds the destination's child in the overlay, so the
  image measures the rectangle of the flight at its first layout and asks for a URL nobody needs (a pop asks for
  the list's shape at the page's size). `test/hero_test.dart` has the control.

There is no automatic detection of a flight: an image in a tooltip or an `OverlayPortal` is also outside any
route, so "no `ModalRoute`" would freeze it. Hence the explicit shuttle.

## The web

Flutter 3.32 and later have no HTML renderer: CanvasKit and skwasm fetch image **bytes** with XHR, so the image
server must send CORS headers on the image **and on the redirect target**. EmgR sends
`Access-Control-Allow-Origin: *` on every route (its `CDN_BASE_URL` host must too). imgproxy:
`IMGPROXY_ALLOW_ORIGIN`. A blank image on the web and fine elsewhere is missing CORS.

- `ImageCdn.webHtmlElementStrategy` (default `never`, Flutter's): `fallback` shows an `<img>` platform view when
  the fetch fails (no CORS needed, but a platform view per image, costly in long lists, and no headers);
  `prefer` always uses `<img>`. Leave `never` unless the server cannot send CORS.
- The browser's HTTP cache works for XHR, so EmgR's `immutable` downloads are cached across reloads.
  `ResizeImage` does not shrink a web `NetworkImage`, so a `DirectUrlBuilder` saves no memory there.
- Browser zoom changes `devicePixelRatio`: the bucket grows, never shrinks.
- `auto` formats: a browser's XHR sends `Accept: */*`, so `.auto` can answer AVIF. Do not use it.
- The package's code lands in `main.dart.js` when an eager page uses it; the shop's size budgets are in
  [`fsp size`](../../fespalier/references/cli-and-config.md).

## Caching

- **Default:** Flutter's in-memory `ImageCache` (1000 images, 100 MB). A 640×640 image is 1.6 MB decoded; a
  3840² one 59 MB, hence `maxPixelRatio` (3) and the last bucket.
- **No disk cache** on Android, iOS or desktop: `dart:io`'s `HttpClient` has no HTTP cache, so a restart
  downloads again. The recipe (the app adds the dependency; Flutter 3.44 and Dart 3.12 or newer):

  ```dart
  // startup.dart with cached_network_image, which is the app's own dependency (a fragment)
  import 'package:cached_network_image/cached_network_image.dart';

  List<Override> startup() => [
    imageCdnProvider.overrideWithValue(
      ImageCdn(
        builder: const ImgproxyUrlBuilder.emgr(baseUrl: 'https://img.example.com'),
        providerFactory: (url) => CachedNetworkImageProvider(url),
      ),
    ),
  ];
  ```

  `extended_image`'s `ExtendedNetworkImageProvider(url, cache: true)` is the alternative without `sqflite`.
  A provider from a factory takes part in the stand-in, the precache and the flight as long as its key is
  available synchronously (`NetworkImage`'s is).

- **The web:** the browser's cache.

## Testing

`package:fespalier_image/testing.dart` has `FakeImages`: a `providerFactory` whose providers record each URL in
`requested` and complete when the test says (`complete(url, image)`, `fail(url)`), or at once when it was made
with `FakeImages(image: image)` (`await createTestImage()` in `setUpAll`). `fakes.cdn(yourCdn)` is your CDN
loading through them, so the test asserts the exact URLs of the app's real builder. A URL the image cache
already holds is not loaded again, and a `FakeImages`' providers are never equal to another's, so an earlier
test's cache is not reused. Put the override in `pumpRouter(overrides:)` and in `test/routes/setup.dart`'s
`overrides(pattern)`.

The app under test is a page with one photo, and the CDN it shares with `startup()`:

```dart
// lib/images.dart
import 'package:fespalier_image/fespalier_image.dart';

const shopImages = ImageCdn(
  builder: ImgproxyUrlBuilder.emgr(
    baseUrl: 'http://localhost:13001',
    sourceBase: 'https://images.example.com/',
  ),
);
```

```dart
// lib/app/page.dart
import 'package:fespalier_image/fespalier_image.dart';
import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: ResponsiveImage('products/3.jpg', width: 160, aspectRatio: 1)),
  );
}
```

```dart
// test/images_test.dart
import 'dart:ui' as ui;

import 'package:fespalier/testing.dart';
import 'package:fespalier_image/fespalier_image.dart';
import 'package:fespalier_image/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/images.dart';

late ui.Image image;

void main() {
  setUpAll(() async => image = await createTestImage());

  testWidgets('the photo asks for the bucket its box needs, and shows at once', (tester) async {
    final fakes = FakeImages(image: image);
    await pumpRouter(
      tester,
      AppRoutes.router(),
      overrides: [imageCdnProvider.overrideWithValue(fakes.cdn(shopImages))],
    );
    // 160 points at 3x is 480 pixels: the 640 bucket, square because of aspectRatio: 1.
    expect(fakes.requested, [
      'http://localhost:13001/unsigned/rs:fill:640:640/aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcHJvZHVjdHMvMy5qcGc.webp',
    ]);
  });

  test('cdn.resolve answers without a widget', () {
    final resolved = shopImages.resolve(
      'products/3.jpg',
      logicalWidth: 40,
      devicePixelRatio: 3,
      aspectRatio: 1,
    );
    expect(resolved?.request.width, 128);
    expect(shopImages.resolve('products/3.jpg', logicalWidth: 0, devicePixelRatio: 3), isNull);
  });
}
```

A pending load is `FakeImages()` without an image: `expect(fakes.isPending(url), isTrue)`, then
`fakes.complete(url, image)` and `await tester.pump()`, or `fakes.fail(url)` for the error view. Tests that
reach an image without the override go through flutter_test's fake `HttpClient` (every request is a 400, with
its own warning) and, with no CDN, print the "not a URL" message.

## Telemetry

With a sink installed, each network load is an `image` operation (since 0.9.0): `TelemetryOp.image` through
`FespalierTelemetry.begin` and `finish`, a span `image {cdn}` such as `image emgr`, with `fespalier.image.cdn`,
`fespalier.image.width` (the bucket), `fespalier.image.preload`, `fespalier.image.result` (`ok` or `error`) and
`fespalier.image.status` (a failed load that carries an HTTP status). One span per load that starts: a cache hit and
a load already in flight make none, and an image in a hero flight starts no load. A load that starts while a page
is being reached is a child of that navigation. **Never the URL, the source, the signature or the error's text**
(the exception's message holds the URL). It needs no `telemetry: true`: image spans follow the installed sink.
`RecordingTelemetry` writes `#4 start image emgr w=640 preload`, `#4 end image ok async` and
`#5 end image error async status=404`. A sink of your own that switches exhaustively over `TelemetryOp` needs
an `image` case (0.9.0), and a `custom` one since 0.11.0: [`fespalier-migration`](../../fespalier-migration/SKILL.md). The conventions are in
[`fespalier-observability`](../../fespalier-observability/references/conventions.md).
