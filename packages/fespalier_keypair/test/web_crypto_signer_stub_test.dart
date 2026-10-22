// What every platform but the web has: a stub that says so. (The browser's own tests are in
// web_crypto_signer_test.dart, which runs only in Chrome.)
@TestOn('vm')
library;

import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('is not supported off the web, and cannot be made', () {
    expect(WebCryptoKeypairSigner.isSupported, isFalse);
    expect(
      () => WebCryptoKeypairSigner(keyId: 'k'),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('works in a browser only'),
        ),
      ),
    );
  });
}
