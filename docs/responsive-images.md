# Images

Since 0.9.0. `package:fespalier_image` shows a network image at the size its layout needs. A
`ResponsiveImage` measures its box, multiplies by the device pixel ratio, rounds up to one of a few widths (a
_bucket_) and asks the app's image CDN for that one: a 40-point avatar downloads 128 pixels, not the original.
Which CDN, and which URL it writes, is the app's choice: imgproxy and EmgR, Cloudinary, imgix, Thumbor, a URL
template, or a srcset that the backend already signed. fespalier's core is unchanged: no file kind, no
`fespalier:` key (a CDN's address differs per flavour and per test, so it is Dart and not `pubspec.yaml`), no
`fsp` command, and `app.g.dart` is the same bytes. An app that does not depend on the package has none of it.

- **`imageCdnProvider`** is the app's `ImageCdn`: the URL builder, the width buckets, the format and the
  quality, set once in `startup()`.
- **`ResponsiveImage('products/3.jpg', aspectRatio: 1)`** is the widget: a placeholder while it loads (or the
  widest variant of the same picture that is already loaded), an error view with a retry, and no new download
  when the layout animates.
- **The URL builders** write the URL for one CDN. They are plain `const` classes whose output is pinned by
  exact-string tests.
- **No key.** The package has no parameter for a signing key and ships no HMAC code. A key in an app is
  public: [Signed image URLs](#signed-image-urls) says what to do instead.
- **`package:fespalier_image/testing.dart`** has `FakeImages`: image loads in a widget test, without a
  network.

## Installing `fespalier_image`

Add it next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.9.1
  fespalier_image:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_image
      ref: v0.9.1
```

<!-- x-release-please-end -->

The package needs Dart 3.8 and Flutter 3.32 or newer. It has no plugin and no dependency of its own beyond
fespalier; `crypto` is a dev dependency of its tests. It does not wrap `cached_network_image` or any CDN's
SDK: it chooses a width and writes a URL, and Flutter's `Image` does the rest ([Caching images](#caching-images)
says how to plug a disk cache in).

## The image CDN: `imageCdnProvider`

The app's choice lives in a provider, overridden in `startup()` like everything else a fespalier app
configures, so a test swaps it with one line:

```dart
// lib/app/startup.dart
Future<List<Override>> startup() async => [
  imageCdnProvider.overrideWithValue(
    const ImageCdn(
      builder: ImgproxyUrlBuilder.emgr(
        baseUrl: String.fromEnvironment('IMAGES', defaultValue: 'https://img.example.com'),
        sourceBase: 'https://images.example.com/',
      ),
      quality: 80,
    ),
  ),
];
```

Without an override the provider holds `const ImageCdn()`, which is no CDN: a source is a URL and is fetched
as it is, decoded at the width the box needs (`ResizeImage`, off the web). A source that is not a URL (it has
no scheme) then prints `fespalier_image: "products/3.jpg" is not a URL and no image CDN is configured, so it
is fetched as it is. Override imageCdnProvider in startup() (docs/responsive-images.md, "Images").` once in a debug build.

| `ImageCdn` field         | What it is                                                                                                                        |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `builder`                | The [URL builder](#url-builders) (`DirectUrlBuilder` by default)                                                                  |
| `buckets`                | The [widths](#buckets-the-widths-an-image-is-fetched-at) an image may be asked for (`ImageBuckets.standard`)                      |
| `format`                 | `ImageFormat.webp` (default), `jpeg`, `png`, `avif` or `auto` (see [URL builders](#url-builders): name a format)                  |
| `quality`                | 1 to 100, or null to leave it to the CDN                                                                                          |
| `maxPixelRatio`          | The device pixel ratio is capped at this (3 by default): a 3.5× phone asks for 3× widths                                          |
| `providerFactory`        | `ImageProvider<Object> Function(String url)`: the provider of a URL. Null is a `NetworkImage`; plug a disk cache in here          |
| `webHtmlElementStrategy` | On the web, whether a failed fetch falls back to an `<img>` element ([Images on the web](#images-on-the-web)); `never` by default |
| `placeholder`            | What shows while an image loads (a box in the theme's `surfaceContainerHighest` by default)                                       |
| `errorBuilder`           | What a failed image shows: `(context, error, retry)`; that box with a broken-image icon by default                                |
| `fadeIn`                 | How long a loaded image fades in; zero (the default) shows it at once                                                             |

Every argument of `ResponsiveImage` that has a counterpart overrides the CDN's for that one image. The provider
is scoped (`dependencies: const []`), so a subtree, a feature or a test can override it in a nested
`ProviderScope`; a provider of yours that reads it must list it in its own `dependencies`. `cdn.copyWith(...)`
makes a variant, and `cdn.resolve(source, logicalWidth: ..., devicePixelRatio: ...)` is the pure function the
widget calls, which answers with the request and its URL: it is how a test (or a precache) knows what a box
asks for without building one.

## Buckets: the widths an image is fetched at

A CDN caches by URL, so an app that asks for 187 pixels here and 191 there gets a miss for each. The widget
rounds up to one of a short list instead, Next.js 16's `imageSizes` and `deviceSizes`, in physical pixels:

```text
32, 48, 64, 96, 128, 256, 384, 640, 750, 828, 1080, 1200, 1920, 2048, 3840
```

The width needed is `(logical × min(devicePixelRatio, maxPixelRatio) − 0.5).ceil()`, and the request gets
the smallest bucket at least that wide (the largest when none is). The half pixel is a tolerance: a 411.43-point
box at 2.625× is 1079.99… pixels, and asks for 1080, not 1200. `maxPixelRatio` is 3 so a phone at 3.5× neither
downloads nor decodes a third more pixels than it can show; a 640×640 image decodes to 1.6 MB and a 3840×3840
one to 59 MB, which is also why the list stops at 3840.

`ImageBuckets([...])` replaces the list, for a CDN that only has presets (`ImageBuckets([128, 640])`, with
the presets named `w128` and `w640`); the widths must be positive and strictly increasing, or the first
use throws `ImageBuckets: the widths must be positive and increasing, got [64, 32]`. Because the widths are
few, the URL that [a precache](#precaching-an-image-behind-a-link) computes is the one the page later asks for,
whatever the padding does to the box by a few points. A srcset has its own widths, and those replace the
buckets ([Already sized: a srcset](#already-sized-a-srcset)).

## `ResponsiveImage`

```dart
ResponsiveImage('products/3.jpg', width: 160, aspectRatio: 1)   // a 160-point square: the 640 bucket at 3×
ResponsiveImage(product.photo, aspectRatio: 16 / 9)             // as wide as the layout gives it
```

| Argument                                           | What it does                                                                                                     |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `source`                                           | A path or public id the CDN knows, a URL, or a srcset                                                            |
| `width`, `height`                                  | The box in logical pixels. A `width` is not measured, so the widget also works inside `IntrinsicWidth`           |
| `aspectRatio`                                      | The shape. The CDN crops to it (`resize`) and the box takes it                                                   |
| `resize`, `fit`, `alignment`                       | `ImageResize.fill` (cover and crop, the default) or `fit`, on the server; `BoxFit` and `Alignment` on the device |
| `quality`, `format`, `extra`, `builder`, `buckets` | Override the CDN's; `extra` is provider-specific options ([URL builders](#url-builders))                         |
| `growWithBox`                                      | Asks for a wider bucket when the box grows past the one shown                                                    |
| `placeholder`, `errorBuilder`, `fadeIn`            | Override the CDN's                                                                                               |
| `semanticLabel`, `excludeFromSemantics`            | `Image`'s                                                                                                        |

**The box.** `width` and `height` make a `SizedBox`; an `aspectRatio` (or both `width` and `height`, which are
one) makes an `AspectRatio`, in a `SizedBox` when there is a `width`; otherwise the parent decides. The image,
the placeholder and the error view fill it, and a side the parent leaves unbounded collapses instead of
throwing. Without a `width`, a `LayoutBuilder` measures: the maximum width when it is bounded, else the
maximum height times the aspect ratio, else the view's width. A `LayoutBuilder` cannot be asked for its
intrinsic size, so inside `IntrinsicHeight` give the widget a `width`.

**The shape is the app's, not the box's.** The server crops only when you say the shape: `aspectRatio: 1`
(or a `width` and a `height`) asks for `rs:fill:640:640`, and without one the request is width-only
(`rs:fit:640:0`) and `fit` crops on the device. A ratio measured from the box (358×200 here, 360×200 there)
would make a new URL, and a new cache entry, for every pixel of padding; a design constant (1, 4/3, 16/9) does
not.

**It chooses once, and only grows.** The bucket is picked at the first layout of an element, again when its
inputs change (the source, the options, the builder, the CDN), and when the view's size or the device pixel
ratio changes, but then only upward; with `growWithBox: true` also when the box grows. It is never smaller
than what is on screen, so an animation of the box (a hero flight, an `AnimatedSize`) asks for one width and
not one per frame, and a window that gets narrower downloads nothing. Browser zoom changes the device pixel
ratio, so the bucket grows and does not shrink.

**It is never blank when something is loaded.** While its URL loads, the widget shows the widest variant of the
same picture (the same source, builder, shape, quality, format and options, at another width) that is already
in the image cache, instead of the placeholder: a thumbnail already on screen stands in for the large image,
with no flicker on a detail page. "Loaded" is read synchronously from Flutter's `ImageCache`. The widget
builds no `Future` and no microtask of its own and starts no timer; only `Image` and the image cache are
involved.

**Placeholders and errors.** `placeholder` is a `WidgetBuilder`; the default is a box in the theme's
`surfaceContainerHighest`. A failed load shows `errorBuilder(context, error, retry)`, and `retry` evicts the
provider and loads again. `fadeIn: Duration(milliseconds: 200)` fades a load that arrives later in over what
was showing (a load that was ready in the first frame does not fade). A builder or bucket that is
misconfigured is a bug in the app and not a network failure: it shows the error view and reports an
`ImageUrlError` once (`FlutterError.reportError`, library `fespalier_image`, while building the URL of the
image); every message of the package is quoted in the `fespalier-troubleshooting` skill.

## URL builders

An `ImageUrlBuilder` turns an `ImageRequest` (the source, a width, an optional height, the resize mode, the
quality, the format and `extra`) into a URL. All of them are `const`, compare equal by their fields, throw an
`ImageUrlError` when misconfigured, and are **unsigned** unless you give them a `signer:`
([Signed image URLs](#signed-image-urls)). `ImageFormat` defaults to `webp`, which Flutter decodes on every
platform. `ImageFormat.auto` asks the CDN to choose from the request's `Accept` header, which Flutter cannot
steer (`dart:io` sends none, a browser's XHR sends `*/*`), so it can answer an AVIF the platform does not
decode: name a format instead.

| Builder                                         | For                                                     | `name` (telemetry)          |
| ----------------------------------------------- | ------------------------------------------------------- | --------------------------- |
| `ImgproxyUrlBuilder`, `ImgproxyUrlBuilder.emgr` | imgproxy, and EmgR (vaam-apps/image-resizer)            | `imgproxy`, `emgr`          |
| `CloudinaryUrlBuilder`                          | Cloudinary delivery URLs                                | `cloudinary`                |
| `ImgixUrlBuilder`                               | imgix                                                   | `imgix`                     |
| `ThumborUrlBuilder`                             | Thumbor and imagor                                      | `thumbor`                   |
| `TemplateUrlBuilder`                            | any CDN whose URLs are a path and a query               | `template` (or the `name:`) |
| `SrcsetUrlBuilder`                              | images that arrive already sized, signed by the backend | `srcset`                    |
| `DirectUrlBuilder`                              | no CDN: the source is the URL (the default)             | `direct`                    |

Subclass `ImageUrlBuilder` for another CDN: `url(request)` and `name` are all it needs, `resizes` says whether
the CDN returns the width asked for (when false, the widget decodes at that width), and `widthsOf(source)`
gives the widths a source exists at.

### imgproxy and EmgR

`{baseUrl}/{signature}/{options}/{source}`. The options are `rs:fill:W:H` (or `rs:fit:W:H`; `rs:fit:W:0`
without a height), then `q:Q` when there is a quality, then `extra`. The source is URL-safe base64 without
padding and the extension (`.webp`), or, with `encoding: ImgproxySourceEncoding.plain`, `plain/` and the
percent-encoded URL. A source without a scheme gets `sourceBase` in front of it.

```dart
const ImgproxyUrlBuilder(baseUrl: 'https://imgproxy.example.com')
// https://imgproxy.example.com/insecure/rs:fill:640:640/aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcGhvdG8uanBn.webp

const ImgproxyUrlBuilder.emgr(baseUrl: 'http://localhost:13001', sourceBase: 'https://images.example.com/')
// photo.jpg at 1080: http://localhost:13001/unsigned/rs:fit:1080:0/aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcGhvdG8uanBn.webp
```

Where EmgR differs from imgproxy, and `.emgr` follows EmgR: an unsigned URL says `unsigned` (imgproxy's docs
say `insecure`), a plain source takes its extension after a dot (`….jpg.png`, imgproxy writes `@png`),
`ImageFormat.auto` is the extension `.auto` (imgproxy: none), and **`g:` is grayscale and gravity is `gr:`**
(`gr:ce`; pass either through `extra`). `processing: (r) => ['pr:w${r.width}']` replaces the options, for a
server that takes presets only. A `baseUrl` that is not an absolute `http` or `https` URL is an
`ImageUrlError`. imgproxy's source URL encryption (`enc/`, Pro) is not built.

### Cloudinary

`{baseUrl}/{cloudName}/image/{upload|fetch}/{transformation}/{source}`, with the transformation's qualifiers
sorted by name as Cloudinary's SDKs write them: `c_fill` (with a height) or `c_limit`, `f_webp`, `h_`, `q_`
(`q_auto` without a quality) and `w_`; then each `extra` as a component of its own. An uploaded asset's
public id that has a `/` and no version gets `v1/` (`forceVersion: false` turns it off), and a fetched URL
is escaped the way Cloudinary expects.

```dart
const CloudinaryUrlBuilder(cloudName: 'demo')
// docs/shoes.jpg at 640×480: https://res.cloudinary.com/demo/image/upload/c_fill,f_webp,h_480,q_auto,w_640/v1/docs/shoes.jpg

const CloudinaryUrlBuilder(cloudName: 'demo', delivery: CloudinaryDelivery.fetch)
// a URL at 256×256, quality 80, jpeg: https://res.cloudinary.com/demo/image/fetch/c_fill,f_jpg,h_256,q_80,w_256/https://images.example.com/photo.jpg
```

There is no `signer:`: a signed Cloudinary URL needs the account's API secret, which also authorises uploads
and deletes. Let the backend send signed URLs and use [a srcset](#already-sized-a-srcset).

### imgix

`https://{domain}/{path}?{parameters}`, the parameters sorted by name: `fm` (or `auto=format`), `fit=crop`
(with a height) or `fit=max`, `h`, `q`, `w`, then each `extra` as `key=value` (it replaces a built-in
parameter of its name). A source with a scheme is one encoded path segment, for imgix's web-proxy sources.

```dart
const ImgixUrlBuilder(domain: 'demos.imgix.net')
// bridge.png at 640×480: https://demos.imgix.net/bridge.png?fit=crop&fm=webp&h=480&w=640
// with extra: ['crop=faces', 'sat=-100']: …?crop=faces&fit=crop&fm=webp&h=480&sat=-100&w=640
```

`domain` is a host name, without a scheme or a path. A `signer:` gets `/path?query` (the parameters sorted,
without `s`) and returns the `s` value.

### Thumbor

`{baseUrl}/{signature}/{path}`, with the path `fit-in/` (a fit with a height), `WxH`, `smart/`
(`smart: true`), `filters:quality(Q):format(webp):…` and the source as written. imagor reads the same.
Unsigned URLs say `unsafe`, which Thumbor refuses unless `ALLOW_UNSAFE_URL` is on.

```dart
const ThumborUrlBuilder(baseUrl: 'https://thumbor.example.com')
// images.example.com/photo.jpg at 640×480: https://thumbor.example.com/unsafe/640x480/filters:format(webp)/images.example.com/photo.jpg
```

A `signer:` gets the path **without** a leading `/` (this is where Thumbor and imgproxy differ) and returns
the signature segment. Encode a query string in the source yourself.

### A URL template

For a CDN whose URLs are a path and a query. `{source}`, `{width}`, `{height}` (0 when not set), `{quality}`
(the request's, else the builder's `quality`, 80) and `{format}` are replaced; anything else in braces is an
error naming it.

```dart
const TemplateUrlBuilder('https://cdn.example.com/{source}?w={width}&h={height}&q={quality}&fm={format}')
// products/1.jpg at 640: https://cdn.example.com/products/1.jpg?w=640&h=0&q=80&fm=webp
```

`resizes` is true when the template has `{width}`; without it the CDN does not size the image, and the widget
decodes it at the width the box needs.

### Already sized: a srcset

When the backend sends the photo's URLs, one per width, signed if they need to be, the source is a srcset and
the URLs are used as they are:

```dart
ResponsiveImage(
  product.photo, // "https://a.example/p-256.webp 256w, https://a.example/p-640.webp 640w"
  builder: const SrcsetUrlBuilder(),
  aspectRatio: 1,
)
```

The widths of the srcset replace the buckets: a 100-point image at 3× needs 300 pixels and gets the 640
candidate; a width wider than the widest candidate gets the widest. `SrcsetUrlBuilder.parse` reads a srcset
(a candidate is a URL and a `640w` descriptor; a URL may contain commas), `SrcsetUrlBuilder.of({256: a,
640: b})` writes one. An empty srcset, or a candidate without a `w` descriptor (`2x`, or none), is an
`ImageUrlError`.

## Signed image URLs

**The package never takes a key.** A key in an app is public: the Android and iOS binaries are unpacked with
standard tools, a Flutter web app's `main.dart.js` is downloaded by every visitor, `--dart-define` values are
compiled in, and obfuscation renames symbols, not string constants. With the key anyone signs any URL, and the
resizer becomes an open image proxy (any allowed source, in every size), a CPU amplifier (a new size per
request defeats its result cache) and a bandwidth bill: the whole point of signing is lost. So no parameter
named or typed like a key or a salt exists in `fespalier_image`, no HMAC, SHA or MD5 code ships in it, and
every builder is unsigned by default. Three ways, in the order to prefer them:

1. **The backend signs.** The API that returns a product returns its photo's URLs, signed, one per width the
   app uses, as a srcset. The page shows `ResponsiveImage(product.photo, builder: const SrcsetUrlBuilder(), aspectRatio: 1)`.
   The backend owns the key, the widths and the options; it works for every CDN, Cloudinary's and imgix's
   secure URLs included; and the URLs arrive with `data.dart`, which `RouteLink` preloads, so the widget stays
   synchronous. A signing endpoint is the same thing called from `data.dart` (`GET /images/sign?src=…&w=256,640`):
   the asynchronous part lives in the data layer, never in the widget.

   ```json
   {
     "id": 3,
     "photo": "https://img.example.com/Kx…/rs:fill:256:256/aHR0….webp 256w, https://img.example.com/Q9…/rs:fill:640:640/aHR0….webp 640w"
   }
   ```

2. **Unsigned, with the server's allowlists.** Fine for development, and for production when the server takes
   presets only, so the URL space is finite (sources × presets) and every result is cached once. EmgR:
   `ALLOW_UNSIGNED_REQUESTS=true`, `ALLOWED_SOURCES=https://images.example.com/`, `ALLOWED_PROCESSING_OPTIONS=pr`
   and `PRESETS=w128=rs:fill:128:128,w640=rs:fill:640:640`; the app writes
   `processing: (r) => ['pr:w${r.width}']` with `buckets: ImageBuckets([128, 640])`. imgproxy:
   `IMGPROXY_ALLOWED_SOURCES` and `IMGPROXY_ONLY_PRESETS=true`. EmgR documents `ALLOW_UNSIGNED_REQUESTS` as a
   local-development escape hatch, and without the allowlists an unsigned server is the open proxy above.
3. **A `signer:` that looks signatures up.** `String Function(String payload)`, called synchronously while the
   widget builds, so it must return at once: for a backend that sends `{payload: signature}` pairs, for
   server-side Dart, and for tests. The payload is documented per builder and pinned by the tests against each
   provider's published examples, so a backend that signs the same string gets the same signature.

| Provider         | Unsigned                                           | Signed                                                | In the package                                         |
| ---------------- | -------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------ |
| imgproxy / EmgR  | `insecure` / `unsigned` (the server must allow it) | HMAC-SHA256 over the salt and the path                | `signer:` gets the path, leading `/` included          |
| Thumbor / imagor | `unsafe` (`ALLOW_UNSAFE_URL`)                      | HMAC-SHA1 over the path without `/`, padded base64url | `signer:` gets the path without a leading `/`          |
| imgix            | a plain source                                     | `s` = MD5 of the token, the path, `?` and the query   | `signer:` gets `/path?query` and returns the `s` value |
| Cloudinary       | strict transformations off                         | `s--8 chars--` from the account's API secret          | no signer: backend URLs through `SrcsetUrlBuilder`     |

The HMAC belongs in **your backend**, never in the app. For an imgproxy or EmgR backend written in Dart:

```dart
// On your server, never in the app: an imgproxy or EmgR signature.
import 'dart:convert';
import 'package:crypto/crypto.dart';

String signImgproxy(List<int> key, List<int> salt, String path) => base64Url
    .encode(Hmac(sha256, key).convert([...salt, ...utf8.encode(path)]).bytes)
    .replaceAll('=', '');
```

## Precaching an image behind a link

Since 0.9.0. A page that shows an image at one size, behind a link that shows it at another, should have the
page's image warm when the link is followed. `ResponsiveImage.precache(context, source, width:, aspectRatio:)`
computes the very URL a `ResponsiveImage` of that size will ask for, with the CDN of `context`
(`imageCdnProvider`), and loads it into Flutter's image cache; `RouteLink(onPreload:)` calls it when the link
starts a preload ([Links: `RouteLink`](navigation.md#links-routelink)):

```dart
// lib/app/products/page.dart: in the row of each product
RouteLink(
  to: ProductRoute(id: p.id),
  preload: Preload.intent,
  // The page shows the photo pagePhotoSize wide: warm that size, not the row's.
  onPreload: (context) => ResponsiveImage.precache(context, p.image, width: pagePhotoSize, aspectRatio: 1),
  builder: (context, follow) => ListTile(...),
)
```

Imperative uses need nothing new: call `ResponsiveImage.precache(context, ...)` before `route.go(context)`. It
completes when the image is loaded or has failed (a failure is dropped: the widget shows its own error), and
without a `width` it uses the view's width. The page's size is known only where there is a `BuildContext`
(`MediaQuery`), not in `route.preload(ref)`. Buckets absorb a few points of padding, so the precache's URL
equals the page's whenever both use the same constant for the photo's size, as `examples/shop` does
(`pagePhotoSize`, used by the page and by the row's `onPreload`); a precache at another bucket than the page's
is a wasted download. A misconfigured builder is reported as `ImageUrlError` with the context
`while precaching the image "products/3.jpg"`, and the call returns at once.

## Images in heroes

A hero flight rebuilds the destination's child at every rectangle of the flight. A widget that measures its
box would ask for a new URL at each, and an image in a hero would download a large variant of the _list's_
shape just to fly. `ResponsiveImage.flightShuttle` is a `Hero.flightShuttleBuilder` that marks the flight: an
image in flight **never starts a load** and shows the widest variant of its source that is already loaded, of
any shape, else its placeholder. `route.imageHero(name, child:)` is `route.hero(name, shuttle:
ResponsiveImage.flightShuttle, child:)`, so it takes the [shared element](layouts.md#shared-elements-heroes) on both pages
in one line each:

```dart
// lib/app/products/page.dart: in the row of each product
leading: ProductRoute(id: p.id).imageHero('photo', child: ResponsiveImage(p.image, width: 40, height: 40)),

// lib/app/products/$id/page.dart
ProductRoute(id: product.id).imageHero('photo', child: ResponsiveImage(product.image, width: 160, height: 160)),
```

`Heroes(shuttle: ResponsiveImage.flightShuttle)` in the root `transition.dart` sets it for every hero (it is
harmless for a hero without an image). With the page's size [precached](#precaching-an-image-behind-a-link)
the shuttle shows that variant at every size of the flight and neither the push nor the pop makes a request;
without a precache it shows the row's thumbnail, and the page shows the thumbnail (the same picture) until its
own image arrives. Different shapes on the two sides (1:1 in the row, 4:3 on the page) still fly the loaded
variant; at rest the page shows its placeholder until its own shape loads, because a stand-in of another shape
would jump.

There is no automatic detection of a flight: an image in a tooltip or an `OverlayPortal` is also outside any
route, so "no `ModalRoute`" would freeze it. Without the shuttle, Flutter's default measures the image again
inside the overlay and it asks for a URL for the rectangle of the moment (`hero_test.dart` has the control).

## Images on the web

Flutter 3.32 and later have no HTML renderer: CanvasKit and skwasm fetch an image's bytes with XHR, so the
image server must send CORS headers on the image **and on the redirect target**. EmgR sends
`Access-Control-Allow-Origin: *` on every route; its `CDN_BASE_URL` host must as well, since it answers the
redirect to the stored file. imgproxy: `IMGPROXY_ALLOW_ORIGIN`. A blank image on the web and nothing on the
other platforms is this.

`ImageCdn.webHtmlElementStrategy` is Flutter's: `never` by default; `fallback` shows an `<img>` platform view
when the fetch fails (no CORS needed, but a platform view per image, which is costly in a long list, and no
request headers); `prefer` always uses `<img>`. Leave it on `never` unless the server cannot send CORS. The
browser's HTTP cache works for XHR, so EmgR's `immutable` downloads are cached across reloads, and
`ResizeImage` does not shrink a web `NetworkImage`, so a `DirectUrlBuilder` saves no memory there. A browser's
XHR sends `Accept: */*`, so `ImageFormat.auto` can answer AVIF: do not use it. The package's code is part of
`main.dart.js` when an eager page uses it ([Web chunk sizes](cli.md#web-chunk-sizes-fsp-size) has the budgets).

## Caching images

By default Flutter's in-memory `ImageCache` (1000 images, 100 MB). On Android, iOS and desktop there is no disk
cache: `dart:io`'s `HttpClient` has no HTTP cache, so a restart downloads again. Plug one in with
`providerFactory`, a one-line recipe on `cached_network_image` (the app adds the dependency; it needs Flutter
3.44 and Dart 3.12, above fespalier's own floor, which is why the package does not depend on it):

```dart
// lib/app/startup.dart
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

`extended_image`'s `ExtendedNetworkImageProvider(url, cache: true)` is the alternative without `sqflite`. A
provider from a factory takes part in everything above (the stand-in, the precache, the flight) as long as its
key is available synchronously, as `NetworkImage`'s is. On the web the browser's cache does it.

## Testing images

`package:fespalier_image/testing.dart` has `FakeImages`: a `providerFactory` whose providers record each URL
and complete when the test says, or at once, with no network, no timer and no `HttpClient` (flutter_test's
fake one answers every request with a 400 and a warning).

```dart
// test/images_test.dart
final fakes = FakeImages(image: await createTestImage()); // made once, in setUpAll
// every load completes in the frame that asks for it; without `image:`, call fakes.complete(url, image) or fakes.fail(url)
await pumpRouter(tester, overrides: [imageCdnProvider.overrideWithValue(fakes.cdn(shopImages))]);
expect(fakes.requested, ['http://localhost:13001/unsigned/rs:fill:128:128/aHR0….webp']);
```

`fakes.cdn(cdn)` is `cdn` loading through the fakes, so the test asserts the exact URLs of the app's real
builder. Put the override in `pumpRouter(overrides:)` and in `test/routes/setup.dart`'s `overrides(pattern)`
([Route smoke tests](cli.md#route-smoke-tests-fsp-test)), or every test that reaches a page with an image goes through the fake `HttpClient`.
A `FakeImages`' providers are equal for one URL of one instance and never equal to another's, so an image
cached by an earlier test is not reused. `cdn.resolve(...)` tests a size rule without a widget.

## Image loads in telemetry

Since 0.9.0. With a telemetry sink installed, each network load is an `image` operation:
`TelemetryOp.image` through `FespalierTelemetry.begin` and `finish`, and a span `image {cdn}` (for example
`image emgr`) with `fespalier.image.cdn`, `fespalier.image.width` (the bucket), `fespalier.image.preload`
(a precache started it), `fespalier.image.result` and, for a failed load that carries one,
`fespalier.image.status` ([Telemetry conventions](observability.md#telemetry-conventions)). One span per load that starts: a
cache hit and a load already in flight make none, and an image in a hero flight starts no load. A load that
starts while a page is being reached is a child of that navigation. **The URL, the source, the signature
and the error's text are never recorded** (the exception's message holds the URL): only the builder's name, the
bucket, the HTTP status and the outcome. Image spans need no `telemetry: true`: they follow the installed
sink, like the auth spans. `RecordingTelemetry` writes them as `#4 start image emgr w=640 preload` and
`#4 end image ok async`, or `#5 end image error async status=404`.

A load that fails (an offline phone) is a failure like any other, so the Errors dashboard of `fsp telemetry`
lists it under the kind "Image load"; filter on `fespalier_operation <> 'image'` if they drown the rest.

An exhaustive `switch` over `TelemetryOp` in a sink of your own needs a case for `image` (since 0.9.0, next to
`auth`): the new value is a source break for such a switch.

## What images cost

An app that does not depend on `fespalier_image` has none of it, not even in analysis, and `app.g.dart` is the
same bytes. One that does gets a widget that builds no `Future` and no microtask of its own while building,
starts no timer, and adds no listener of its own except a `fadeIn`'s animation (only when you ask for one);
the stand-in and the "loaded" check read Flutter's `ImageCache` synchronously. The one process-wide state is
a list of the providers it made, by source (256 sources, least recently used first out), so a thumbnail can
stand in for the large image; it is keyed by the builder and the provider factory, so two CDNs and the fakes of
two tests never see each other's entries.
