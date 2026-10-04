# The URL builders

Since 0.9.0 (`packages/fespalier_image/lib/src/builders/`). An `ImageUrlBuilder` turns an `ImageRequest` (the
source, a width, an optional height, `resize`, `quality`, `format`, `extra`) into a URL. Widths and heights
are physical pixels, a bucket. All built-ins are `const`, compare equal by their fields (a closure by
identity), throw an `ImageUrlError` when misconfigured, and are **unsigned** unless given a `signer:`
([`signing.md`](signing.md)). Each URL below is an exact string asserted by `test/builders_test.dart`.

`P` is `https://images.example.com/photo.jpg`, and `B64(P)` is its URL-safe base64 without padding,
`aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcGhvdG8uanBn`.

| Builder                   | `name` (telemetry)   | `resizes`             | Signer payload                                   |
| ------------------------- | -------------------- | --------------------- | ------------------------------------------------ |
| `ImgproxyUrlBuilder`      | `imgproxy`           | yes                   | the path after the signature, leading `/`        |
| `ImgproxyUrlBuilder.emgr` | `emgr`               | yes                   | the same                                         |
| `CloudinaryUrlBuilder`    | `cloudinary`         | yes                   | none: no signer                                  |
| `ImgixUrlBuilder`         | `imgix`              | yes                   | `/path?query` (sorted, without `s`)              |
| `ThumborUrlBuilder`       | `thumbor`            | yes                   | the path after the signature, **no** leading `/` |
| `TemplateUrlBuilder`      | `template` (`name:`) | when it has `{width}` | none                                             |
| `SrcsetUrlBuilder`        | `srcset`             | yes                   | none: the URLs are used as they are              |
| `DirectUrlBuilder`        | `direct`             | no                    | none                                             |

`resizes: false` means the CDN does not return the width asked for, so the widget decodes the image at that
width (`ResizeImage`, policy `fit`, no upscaling) and an original is never held in memory at full size. (On the
web `ResizeImage` does not shrink a `NetworkImage`.) `widthsOf(source)` is non-null only for a srcset: its
widths replace the buckets. Subclass `ImageUrlBuilder` for a CDN that is not here: `url(request)` and `name`
are required.

## imgproxy and EmgR

```text
{baseUrl}/{signature}/{options joined by /}/{source}
signature  = signer(path) ?? 'insecure' (imgproxy) | 'unsigned' (EmgR)
path       = '/' + options + '/' + source            (what the signer gets)
options    = rs:{fill|fit}:{W}:{H or 0} [q:{Q}] [extra...]    (`processing:` replaces all of it)
source     = base64url_nopad(src) + ext              (encoding: base64, the default)
           | 'plain/' + Uri.encodeComponent(src) + pext      (encoding: plain)
src        = the source when it has a scheme, else sourceBase + source
ext        = '.' + extension; for auto: '.auto' (EmgR), none (imgproxy)
pext       = '@' + extension (imgproxy) | '.' + extension (EmgR); for auto: none (imgproxy), '.auto' (EmgR)
```

`rs:fill` when there is a height and `resize` is `fill`, else `rs:fit`. `baseUrl` must be an absolute `http` or
`https` URL (a trailing `/` is ignored). `processing: (r) => ['pr:w${r.width}']` is for a server that takes
presets only.

| Builder and request                                                                                        | URL                                                                                                         |
| ---------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `ImgproxyUrlBuilder(baseUrl: 'https://imgproxy.example.com/')`, `P` at 640×640                             | `https://imgproxy.example.com/insecure/rs:fill:640:640/B64(P).webp`                                         |
| the same with `encoding: plain`, `P` at 640, png                                                           | `https://imgproxy.example.com/insecure/rs:fit:640:0/plain/https%3A%2F%2Fimages.example.com%2Fphoto.jpg@png` |
| the same, `P` at 640, `ImageFormat.auto`                                                                   | `https://imgproxy.example.com/insecure/rs:fit:640:0/B64(P)`                                                 |
| the same, `P` at 256×256, quality 75, extra `['bl:2', 'sh:0.5']`                                           | `https://imgproxy.example.com/insecure/rs:fill:256:256/q:75/bl:2/sh:0.5/B64(P).webp`                        |
| `.emgr(baseUrl: 'http://localhost:13001', sourceBase: 'https://images.example.com/')`, `photo.jpg` at 1080 | `http://localhost:13001/unsigned/rs:fit:1080:0/B64(P).webp`                                                 |
| `.emgr(..., encoding: plain)`, `P` at 640, png                                                             | `http://localhost:13001/unsigned/rs:fit:640:0/plain/https%3A%2F%2Fimages.example.com%2Fphoto.jpg.png`       |
| `.emgr(...)`, `P` at 640, `auto`                                                                           | `http://localhost:13001/unsigned/rs:fit:640:0/B64(P).auto`                                                  |
| `.emgr(..., processing: (r) => ['pr:w${r.width}'])`, `P` at 640                                            | `http://localhost:13001/unsigned/pr:w640/B64(P).webp`                                                       |

**EmgR is imgproxy's grammar with differences, and `.emgr` follows EmgR:** unsigned is `unsigned` (and the
server needs `ALLOW_UNSIGNED_REQUESTS=true`; without a key it refuses to start otherwise), a plain source takes
`.ext` and not `@ext`, `auto` is the extension `.auto`, and **`g:` is grayscale and gravity is `gr:`**
(`gr:ce`, `gr:fp:x:y`; `sm` and `obj` are rejected with a 400). Pass those through `extra`. EmgR answers `301` to
`/api/images/files/{sha256}.{ext}` (`Cache-Control: public, max-age=31536000, immutable`), which `dart:io` and
browsers follow; it sends CORS on every route, and its `CDN_BASE_URL` host must too. Its allowlists:
`ALLOWED_SOURCES`, `ALLOWED_PROCESSING_OPTIONS` and `PRESETS`. Not built: imgproxy's source encryption
(`enc/`, Pro) and `IMGPROXY_TRUSTED_SIGNATURES`.

## Cloudinary

```text
{baseUrl}/{cloudName}/image/{upload|fetch}/{main}[/{extra...}]/{source}
main    = qualifiers sorted by name, comma-joined:
          c_{fill|limit}, f_{webp|jpg|png|avif|auto}, h_{H} (with a height), q_{Q|auto}, w_{W}
source  = upload: 'v1/' + id when forceVersion and the id has '/' and does not start with v<digits>/; else the id
          fetch:  the URL, percent-encoding every byte outside A-Za-z0-9 - _ . ! ~ * ' ( ) ; : @ & = + $ , /
```

`c_fill` with a height and `resize: fill`, else `c_limit` (no upscaling). Each `extra` is a component of its
own, after `main`. `cloudName` with a `/` or a `:`, or empty, is an error, and so is a `baseUrl` that is not
`http(s)`. No `_a=` analytics parameter. **No signer** (it would need the account's API secret).

| Request (cloud `demo`)                                     | URL                                                                                                              |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `docs/shoes.jpg` at 640×480                                | `https://res.cloudinary.com/demo/image/upload/c_fill,f_webp,h_480,q_auto,w_640/v1/docs/shoes.jpg`                |
| `sample.jpg` at 1080                                       | `https://res.cloudinary.com/demo/image/upload/c_limit,f_webp,q_auto,w_1080/sample.jpg`                           |
| fetch, `P` at 256×256, quality 80, jpeg                    | `https://res.cloudinary.com/demo/image/fetch/c_fill,f_jpg,h_256,q_80,w_256/https://images.example.com/photo.jpg` |
| fetch, `https://images.example.com/p.jpg?v=2` at 640       | `https://res.cloudinary.com/demo/image/fetch/c_limit,f_webp,q_auto,w_640/https://images.example.com/p.jpg%3Fv=2` |
| `docs/shoes.jpg` at 640×480, auto, extra `['e_grayscale']` | `https://res.cloudinary.com/demo/image/upload/c_fill,f_auto,h_480,q_auto,w_640/e_grayscale/v1/docs/shoes.jpg`    |
| `v1712/docs/shoes.jpg` at 640                              | `https://res.cloudinary.com/demo/image/upload/c_limit,f_webp,q_auto,w_640/v1712/docs/shoes.jpg`                  |

## imgix

```text
{https|http}://{domain}{path}?{query}[&s={signer(path + '?' + query)}]
path   = '/' + Uri.encodeComponent(source) when it has a scheme (a web-proxy source),
         else '/' + each '/'-separated segment Uri.encodeComponent-ed (a leading '/' dropped first)
query  = parameters sorted by name, Uri.encodeQueryComponent on both sides:
         auto=format (auto) | fm={webp|jpg|png|avif}; fit={crop|max}; h (with a height); q (when set); w;
         then each extra 'key=value' (it replaces a built-in parameter of its name)
```

`fit=crop` with a height and `resize: fill`, else `fit=max`. No `ixlib`. `domain` with a scheme or a `/`, or
empty, is an error; an `extra` without `=` is an error.

| Request (domain `demos.imgix.net`)                          | URL                                                                                          |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `bridge.png` at 640×480                                     | `https://demos.imgix.net/bridge.png?fit=crop&fm=webp&h=480&w=640`                            |
| `products/1 copy.jpg` at 1080, quality 60, auto             | `https://demos.imgix.net/products/1%20copy.jpg?auto=format&fit=max&q=60&w=1080`              |
| `P` at 384                                                  | `https://demos.imgix.net/https%3A%2F%2Fimages.example.com%2Fphoto.jpg?fit=max&fm=webp&w=384` |
| `bridge.png` at 640×480, extra `['crop=faces', 'sat=-100']` | `https://demos.imgix.net/bridge.png?crop=faces&fit=crop&fm=webp&h=480&sat=-100&w=640`        |

## Thumbor (and imagor)

```text
{baseUrl}/{signer(path) ?? 'unsafe'}/{path}
path = ['fit-in' (a height and fit)], '{W}x{H or 0}', ['smart'],
       ['filters:' + (quality(Q), format(webp|jpeg|png|avif) unless auto, extra...) joined by ':'],
       source                                                  joined by '/'
```

The source is written as given (Thumbor reads `images.example.com/photo.jpg` and unencoded URLs; encode a
query string yourself). `unsafe` URLs need `ALLOW_UNSAFE_URL` on the server.

| Request (`baseUrl: 'https://thumbor.example.com'`)                          | URL                                                                                                                     |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `images.example.com/photo.jpg` at 640×480                                   | `https://thumbor.example.com/unsafe/640x480/filters:format(webp)/images.example.com/photo.jpg`                          |
| the same source at 1080, quality 80, jpeg (a `baseUrl` with a trailing `/`) | `https://thumbor.example.com/unsafe/1080x0/filters:quality(80):format(jpeg)/images.example.com/photo.jpg`               |
| the same source at 640×640, fit, `smart: true`, extra `['grayscale()']`     | `https://thumbor.example.com/unsafe/fit-in/640x640/smart/filters:format(webp):grayscale()/images.example.com/photo.jpg` |

## A URL template

`TemplateUrlBuilder('https://cdn.example.com/{source}?w={width}&h={height}&q={quality}&fm={format}')`: the
placeholders are `{source}`, `{width}`, `{height}` (0 when not set), `{quality}` (the request's, else the
builder's `quality`, 80) and `{format}` (`webp`, `jpg`, `png`, `avif`, `auto`); any other name in braces is an
error that names it. `products/1.jpg` at 640 gives `https://cdn.example.com/products/1.jpg?w=640&h=0&q=80&fm=webp`.
`resizes` is true only when the template has `{width}`; `name:` sets the telemetry name.

## A srcset

`SrcsetUrlBuilder` reads the source as a srcset and uses its URLs as they are, so the backend can sign them.
Its widths replace the buckets: `SrcsetUrlBuilder.parse(...)` gives `{256: url, 640: url, 1080: url}`; a
100-point image at 3× (300 pixels) gets the 640 candidate, and one wider than the widest candidate gets the
widest. `url(request)` picks the candidate of exactly the request's width (it came from `widthsOf`), else the
smallest wider one, else the widest.

Parsing: whitespace and commas between candidates are skipped; a candidate is a URL (a run of non-whitespace,
so `https://x/a,b.jpg 100w` keeps its comma; a URL ending in `,` has no descriptor) and a descriptor up to the
next comma, which must be `Nw`; a repeated width keeps the first. `SrcsetUrlBuilder.of({640: 'b', 256: 'a'})`
writes `a 256w, b 640w`, in increasing width. An empty srcset, and a candidate with no width descriptor (`2x`,
`100h`, none), are errors.

## `ImageUrlError` messages

Every one is quoted exactly, with its cause and fix, in
[`fespalier-troubleshooting`](../../fespalier-troubleshooting/references/diagnostics-images.md). A widget that
meets one shows its error view and reports it once with `FlutterError.reportError` (library
`fespalier_image`): a misconfigured builder is a bug in the app.
