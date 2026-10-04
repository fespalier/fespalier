// Test-only signers on `package:crypto`, to pin each builder's payload against what the providers
// publish. The package computes no signature and takes no key: a backend signs, and this is what
// the backend's signature must agree with.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fespalier_image/fespalier_image.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _hex(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

/// imgproxy's and EmgR's signature: URL-safe base64 without padding of HMAC-SHA256 over the
/// salt and the path.
ImageSigner hmacSha256(String keyHex, String saltHex) =>
    (path) => base64Url
        .encode(
          Hmac(
            sha256,
            _hex(keyHex),
          ).convert([..._hex(saltHex), ...utf8.encode(path)]).bytes,
        )
        .replaceAll('=', '');

/// Thumbor's signature: padded URL-safe base64 of HMAC-SHA1 over the path.
ImageSigner hmacSha1(String key) =>
    (path) => base64Url.encode(
      Hmac(sha1, utf8.encode(key)).convert(utf8.encode(path)).bytes,
    );

/// imgix's signature: the hex MD5 of the token and the path with its query.
ImageSigner md5Hex(String token) =>
    (payload) => md5.convert(utf8.encode('$token$payload')).toString();

const p = 'https://images.example.com/photo.jpg';
const b64p = 'aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcGhvdG8uanBn';

// EmgR's documented placeholders: key "my-signing-key", salt "my-salt".
const emgrKey = '6d792d7369676e696e672d6b6579';
const emgrSalt = '6d792d73616c74';

void main() {
  test('the helper agrees with imgproxy\'s documented signature', () {
    expect(
      hmacSha256('736563726574', '68656c6c6f')(
        '/rs:fill:300:400:0/g:sm/aHR0cDovL2V4YW1w/bGUuY29tL2ltYWdl/cy9jdXJpb3NpdHku/anBn.png',
      ),
      'oKfUtW34Dvo2BGQehJFR4Nr0_rIjOtdtzJ3QFsUcXH8',
    );
  });

  test('E1: EmgR\'s documented URL, and the signer gets exactly the path', () {
    final seen = <String>[];
    final sign = hmacSha256(emgrKey, emgrSalt);
    final builder = ImgproxyUrlBuilder.emgr(
      baseUrl: 'http://localhost:13001',
      signer: (path) {
        seen.add(path);
        return sign(path);
      },
    );
    expect(
      builder.url(
        const ImageRequest(
          p,
          width: 300,
          height: 300,
          quality: 80,
          format: ImageFormat.jpeg,
        ),
      ),
      'http://localhost:13001/de7BKgwO8wFeNZWRWgp3UB9jKwOkVoYM_eMKau2ECgw/'
      'rs:fill:300:300/q:80/$b64p.jpg',
    );
    expect(seen, ['/rs:fill:300:300/q:80/$b64p.jpg']);
  });

  test('E2: EmgR\'s second documented URL', () {
    final builder = ImgproxyUrlBuilder.emgr(
      baseUrl: 'http://localhost:13001',
      signer: hmacSha256(emgrKey, emgrSalt),
    );
    expect(
      builder.url(
        const ImageRequest(
          p,
          width: 200,
          height: 200,
          resize: ImageResize.fit,
          quality: 80,
        ),
      ),
      'http://localhost:13001/USj4F2ERoKKugAeQ54JQct8oGudbkUzGYdIuJncZawk/'
      'rs:fit:200:200/q:80/$b64p.webp',
    );
  });

  test('T1: Thumbor\'s published vector', () {
    final builder = ThumborUrlBuilder(
      baseUrl: 'https://thumbor.example.com',
      signer: hmacSha1('my-security-key'),
    );
    expect(
      builder.url(
        const ImageRequest(
          'my.server.com/some/path/to/image.jpg',
          width: 300,
          height: 200,
          format: ImageFormat.auto,
        ),
      ),
      'https://thumbor.example.com/8ammJH8D-7tXy6kU3lTvoXlhu4o=/300x200/'
      'my.server.com/some/path/to/image.jpg',
    );
  });

  test('imgix\'s documented MD5, and X3 through the builder', () {
    expect(
      md5Hex('test1234')('/bridge.png?h=100&w=100'),
      'bb8f3a2ab832e35997456823272103a4',
    );
    final seen = <String>[];
    final sign = md5Hex('test1234');
    final builder = ImgixUrlBuilder(
      domain: 'demos.imgix.net',
      signer: (payload) {
        seen.add(payload);
        return sign(payload);
      },
    );
    expect(
      builder.url(const ImageRequest('bridge.png', width: 640, height: 480)),
      'https://demos.imgix.net/bridge.png?fit=crop&fm=webp&h=480&w=640&s=39f2cbb9945bc1255a56c7b94f65825c',
    );
    expect(seen, ['/bridge.png?fit=crop&fm=webp&h=480&w=640']);
  });

  test('the library has no key, no secret handling and no signature code', () {
    // The design: a key in an app is public, so there is nowhere to put one. `signer:` is a
    // callback; `package:crypto` is a dev dependency of these tests only.
    final offenders = <String>[];
    final forbidden = {
      'a signature algorithm': RegExp(
        r'sha1|sha256|sha512|md5|hmac|package:crypto',
        caseSensitive: false,
      ),
      'a salt': RegExp(r'\bsalt\b', caseSensitive: false),
      // A parameter or field that holds a key: `String key`, `this.key`, `this.signingKey`,
      // `key:` of a named parameter that is not a widget key.
      'a key parameter': RegExp(
        r'\b(String|List<int>|Uint8List)\??\s+(\w*[kK]ey|secret\w*)\b|\bthis\.(signingKey|secret\w*|apiKey|key)\b',
      ),
    };
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final text = entity.readAsStringSync();
      for (final MapEntry(:key, :value) in forbidden.entries) {
        if (value.hasMatch(text)) offenders.add('${entity.path}: $key');
      }
    }
    expect(offenders, isEmpty);
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final deps = pubspec.substring(0, pubspec.indexOf('dev_dependencies:'));
    expect(deps, isNot(contains('crypto')));
  });
}
