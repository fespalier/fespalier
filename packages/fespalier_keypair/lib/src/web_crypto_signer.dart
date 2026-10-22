// The web's key is `WebCryptoKeypairSigner`; every other platform links a stub that says so, so
// no file outside this one needs to know which it got. `dart.library.js_interop` is true for
// dart2js, dart2wasm and DDC.
export 'web_crypto_signer_stub.dart'
    if (dart.library.js_interop) 'web_crypto_signer_web.dart';
