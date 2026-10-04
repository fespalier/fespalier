# Signed image URLs, and why the app never holds the key

Since 0.9.0. `fespalier_image` has **no parameter for a key or a salt and ships no HMAC, SHA or MD5 code**, and
`test/signing_test.dart` greps its `lib/` to keep it so. `package:crypto` is a dev dependency of that test
only. Never add a `key:` or `salt:` parameter, and never write an HMAC into a `signer:`: this page says why and
what to do instead.

## The risk

A key in an app is public. The Android and iOS binaries are unpacked with standard tools; a Flutter web app's
`main.dart.js` is downloaded by every visitor; `--dart-define` values are compiled in; obfuscation renames
symbols, not string constants. With the key anyone signs any URL, and the resizer becomes

- an **open image proxy** (any allowed source, in every size),
- a **CPU amplifier** (a new size per request defeats its result cache), and
- a bandwidth bill.

imgproxy's and EmgR's whole point of signing is then lost. Every builder is **unsigned by default**
(`insecure`, `unsigned`, `unsafe`, no `s`), and the default `ImageCdn()` is no CDN at all: the safe path needs
no secret anywhere.

## The three ways, in the order to prefer them

1. **The backend signs (recommended for production).** The API that returns a product returns its photo's URLs,
   signed, one per width the app uses, as a srcset string. The page shows
   `ResponsiveImage(product.photo, builder: const SrcsetUrlBuilder(), aspectRatio: 1)`. The backend owns the
   key, the widths and the options. It works for every CDN, Cloudinary's and imgix's secure URLs included. The
   URLs arrive with `data.dart`, which `RouteLink` preloads, so the widget stays synchronous.

   ```json
   {
     "id": 3,
     "photo": "https://img.example.com/Kx…/rs:fill:256:256/aHR0….webp 256w, https://img.example.com/Q9…/rs:fill:640:640/aHR0….webp 640w"
   }
   ```

   A **signing endpoint** is the same thing called from the app's `data.dart`
   (`GET /images/sign?src=…&w=256,640`): the asynchronous part lives in the data layer, never in the widget (no
   frame and no request per image build).

2. **Unsigned, with a server allowlist (development, and production with presets).** The URL space is then
   finite (sources × presets) and every result is cached once.
   - **EmgR:** `ALLOW_UNSIGNED_REQUESTS=true`, `ALLOWED_SOURCES=https://images.example.com/`,
     `ALLOWED_PROCESSING_OPTIONS=pr`, `PRESETS=w128=rs:fill:128:128,w640=rs:fill:640:640`. The app writes
     `processing: (r) => ['pr:w${r.width}']` with `buckets: const ImageBuckets([128, 640])`.
   - **imgproxy:** `IMGPROXY_ALLOWED_SOURCES` and `IMGPROXY_ONLY_PRESETS=true`.
   - EmgR documents `ALLOW_UNSIGNED_REQUESTS` as a **local-development escape hatch**, and says so; without
     the allowlists an unsigned server is the open proxy above.

3. **A `signer:` that looks signatures up.** `typedef ImageSigner = String Function(String payload)`, called
   **synchronously while a widget builds**: it must return at once. For a backend that sends
   `{payload: signature}` pairs, for server-side Dart, and for tests. The payload per builder is exact and
   pinned by tests against each provider's published examples, so a backend that signs the same string gets
   the same signature.

## Per provider

| Provider         | Unsigned                                           | Signed                                                            | In the package                                                                                            |
| ---------------- | -------------------------------------------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| imgproxy / EmgR  | `insecure` / `unsigned` (the server must allow it) | HMAC-SHA256 over the salt and the path, base64url without padding | `signer:` gets `path`: `/rs:fill:300:300/q:80/B64(P).jpg`, leading `/` included                           |
| Thumbor / imagor | `unsafe` (`ALLOW_UNSAFE_URL`)                      | HMAC-SHA1 over the path without `/`, padded base64url             | `signer:` gets the path without a leading `/`: `300x200/my.server.com/some/path/to/image.jpg`             |
| imgix            | a plain source                                     | `s` = hex MD5 of the token, the path, `?` and the query           | `signer:` gets `/bridge.png?fit=crop&fm=webp&h=480&w=640` (sorted, without `s`) and returns the `s` value |
| Cloudinary       | strict transformations off                         | `s--8 chars--` from the **account's API secret**                  | **no signer**: backend URLs through `SrcsetUrlBuilder`. The secret also authorises uploads and deletes    |

The published vectors the tests check (the key and salt are those providers' own placeholders):

- imgproxy: key `secret`, salt `hello` (hex `736563726574`, `68656c6c6f`), path
  `/rs:fill:300:400:0/g:sm/aHR0cDovL2V4YW1w/bGUuY29tL2ltYWdl/cy9jdXJpb3NpdHku/anBn.png` gives
  `oKfUtW34Dvo2BGQehJFR4Nr0_rIjOtdtzJ3QFsUcXH8`.
- EmgR: key `my-signing-key`, salt `my-salt`, `P` at 300×300, quality 80, jpeg gives
  `http://localhost:13001/de7BKgwO8wFeNZWRWgp3UB9jKwOkVoYM_eMKau2ECgw/rs:fill:300:300/q:80/B64(P).jpg`.
- Thumbor: key `my-security-key`, `300x200/my.server.com/some/path/to/image.jpg` gives `8ammJH8D-7tXy6kU3lTvoXlhu4o=`.
- imgix: token `test1234`, `/bridge.png?h=100&w=100` gives `bb8f3a2ab832e35997456823272103a4`.

`P` is `https://images.example.com/photo.jpg` and `B64(P)` its URL-safe base64 without padding.

Not built: imgproxy's source URL encryption (`enc/`, Pro), `IMGPROXY_TRUSTED_SIGNATURES`, Cloudinary token
authentication.

## The HMAC, in backend code only

For an imgproxy or EmgR backend written in Dart, **on the server, never in the app**:

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';

String signImgproxy(List<int> key, List<int> salt, String path) => base64Url
    .encode(Hmac(sha256, key).convert([...salt, ...utf8.encode(path)]).bytes)
    .replaceAll('=', '');
```

(A fragment, not a sample: it belongs to a server project, not to the app that the samples build.)

## Reviewing an app that signs

A `signer:` closure that contains an HMAC, a constant that looks like a key, a `--dart-define` named
`…KEY`, `…SECRET` or `…SALT`, or an `.env` asset: the key ships. Replace it with the backend's signed URLs
(way 1) or a lookup (way 3). An app whose CDN is unsigned in production without allowlists on the server
should say so in review: the resizer is an open proxy.
