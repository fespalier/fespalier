import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'role.dart';
import 'signer.dart';

/// The `{publicKey, privateKey}` dictionary `SubtleCrypto.generateKey` returns for an ECDSA key
/// (`package:web` has no type for it).
extension type _CryptoKeyPair._(JSObject _) implements JSObject {
  external web.CryptoKey get publicKey;
  external web.CryptoKey get privateKey;
}

/// A non-extractable P-256 `CryptoKey` of the browser (since 0.21.0): the web's key.
///
/// The private key is made with `extractable: false`, so no script on the page, this one
/// included, can read it out: it can only ask the browser to sign. It is stored in IndexedDB
/// (database `fespalier_keypair`, store `keys`, one record per [keyId]) as the key object itself,
/// which a browser keeps without ever exposing the bytes, so the key survives a reload and a
/// restart. Only the public key is exported, as a JWK.
///
/// What this is not: a secure element (`isHardwareBacked` is false), and not a defence against
/// script running on your origin, which can sign anything it likes while the page is open (the
/// same as the ambient key of a phone). It stops theft of the key by anything that can read
/// storage, and a copy of it to another browser, which is what binding a token to a key is for.
/// Clearing site data deletes the key; the session bound to it ends as `keyLost`.
///
/// It is [KeyRole.ambient] only: the browser has no user-presence prompt for a `CryptoKey`.
/// `KeyRole.userPresent` is refused at construction with an [UnsupportedError], never answered
/// with a key that does not prompt.
///
/// UNCHECKED IN CI: no job of this repository runs this file in a browser. Its tests
/// (`test/web_crypto_signer_test.dart`) were run by hand in Chrome (`flutter test --platform
/// chrome` with DDC, and `--wasm`) and passed; they have not been run on Firefox or Safari, nor
/// with dart2js, nor in a private window (where a browser may refuse IndexedDB), so
/// treat those as unverified.
final class WebCryptoKeypairSigner implements KeypairSigner {
  /// A signer for the key [keyId]. [role] other than [KeyRole.ambient] throws an
  /// [UnsupportedError].
  WebCryptoKeypairSigner({
    required this.keyId,
    KeyRole role = KeyRole.ambient,
  }) {
    if (role != KeyRole.ambient) {
      throw UnsupportedError(
        'fespalier_keypair: the web has no user-present key (the browser cannot '
        'prompt for a CryptoKey); a KeyRole.userPresent request is refused rather than '
        'answered with a key that does not prompt',
      );
    }
  }

  static const String _database = 'fespalier_keypair';
  static const String _store = 'keys';

  /// Whether this browser can hold the key: a secure context with `crypto.subtle` and
  /// IndexedDB.
  static bool get isSupported {
    try {
      final window = web.window as JSObject;
      if (!web.window.isSecureContext) return false;
      if (!window.hasProperty('indexedDB'.toJS).toDart) return false;
      final crypto = window.getProperty<JSAny?>('crypto'.toJS);
      if (crypto == null) return false;
      return (crypto as JSObject).getProperty<JSAny?>('subtle'.toJS) != null;
    } on Object {
      return false;
    }
  }

  /// The key id.
  final String keyId;

  @override
  KeyRole get role => KeyRole.ambient;

  Future<_CryptoKeyPair>? _pair;

  web.SubtleCrypto get _subtle => web.window.crypto.subtle;

  /// The key, made when there is none. Two callers that arrive together wait for the same
  /// creation, and a failure is not remembered.
  Future<_CryptoKeyPair> _key() {
    final known = _pair;
    if (known != null) return known;
    final made = _loadOrCreate();
    _pair = made;
    made.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_pair, made)) _pair = null;
      },
    );
    return made;
  }

  Future<_CryptoKeyPair> _loadOrCreate() async {
    final existing = await _read();
    if (existing != null) return existing;
    final generated =
        (await _subtle
                .generateKey(
                  <String, Object>{
                    'name': 'ECDSA',
                    'namedCurve': 'P-256',
                  }.jsify()!,
                  false,
                  <JSString>['sign'.toJS].toJS,
                )
                .toDart)!
            as _CryptoKeyPair;
    // Another tab may have made it between the read and now: the first one stored wins, and
    // every tab signs with it.
    return _putIfAbsent(generated);
  }

  @override
  Future<Map<String, String>> publicJwk() async {
    final pair = await _key();
    final jwk =
        (await _subtle.exportKey('jwk', pair.publicKey).toDart)!
            as web.JsonWebKey;
    return <String, String>{
      'crv': 'P-256',
      'kty': 'EC',
      'x': jwk.x,
      'y': jwk.y,
    };
  }

  @override
  Future<Uint8List> sign(Uint8List signingInput, {String? reason}) async {
    final pair = await _key();
    final signature =
        (await _subtle
                .sign(
                  <String, Object>{'name': 'ECDSA', 'hash': 'SHA-256'}.jsify()!,
                  pair.privateKey,
                  signingInput.toJS,
                )
                .toDart)!
            as JSArrayBuffer;
    // The Web Crypto API's ECDSA signature is already IEEE P1363 r||s (64 bytes for P-256).
    return signature.toDart.asUint8List();
  }

  @override
  Future<bool> isHardwareBacked() async => false;

  @override
  Future<bool> exists() async => await _read() != null;

  @override
  Future<void> deleteKey() async {
    _pair = null;
    await _withStore('readwrite', (store, finish) {
      final request = store.delete(keyId.toJS);
      request.onerror = ((web.Event _) => finish.error(request.error)).toJS;
    });
  }

  Future<_CryptoKeyPair?> _read() async {
    _CryptoKeyPair? found;
    await _withStore('readonly', (store, finish) {
      final request = store.get(keyId.toJS);
      request.onsuccess = ((web.Event _) {
        final result = request.result;
        if (result != null) found = result as _CryptoKeyPair;
      }).toJS;
      request.onerror = ((web.Event _) => finish.error(request.error)).toJS;
    });
    return found;
  }

  Future<_CryptoKeyPair> _putIfAbsent(_CryptoKeyPair candidate) async {
    var winner = candidate;
    await _withStore('readwrite', (store, finish) {
      // Read and write in one transaction, from inside the read's own callback, so no other tab
      // can slip between them.
      final request = store.get(keyId.toJS);
      request.onsuccess = ((web.Event _) {
        final result = request.result;
        if (result != null) {
          winner = result as _CryptoKeyPair;
        } else {
          store.put(candidate, keyId.toJS).onerror =
              ((web.Event _) => finish.error(null)).toJS;
        }
      }).toJS;
      request.onerror = ((web.Event _) => finish.error(request.error)).toJS;
    });
    return winner;
  }

  /// Opens the database, runs [work] in one transaction on the store, and completes when the
  /// transaction does (not when its last request does, which is before it is stored).
  Future<void> _withStore(
    String mode,
    void Function(web.IDBObjectStore store, _Finish finish) work,
  ) async {
    final database = await _open();
    try {
      final done = Completer<void>();
      final transaction = database.transaction(_store.toJS, mode);
      final finish = _Finish(done);
      transaction.oncomplete = ((web.Event _) {
        if (!done.isCompleted) done.complete();
      }).toJS;
      transaction.onerror = ((web.Event _) => finish.error(
        transaction.error,
      )).toJS;
      transaction.onabort = ((web.Event _) => finish.error(
        transaction.error,
      )).toJS;
      work(transaction.objectStore(_store), finish);
      await done.future;
    } finally {
      database.close();
    }
  }

  Future<web.IDBDatabase> _open() {
    final opened = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_database, 1);
    request.onupgradeneeded = ((web.Event _) {
      (request.result! as web.IDBDatabase).createObjectStore(_store);
    }).toJS;
    request.onsuccess = ((web.Event _) {
      opened.complete(request.result! as web.IDBDatabase);
    }).toJS;
    request.onerror = ((web.Event _) {
      opened.completeError(
        StateError(
          'fespalier_keypair: IndexedDB could not be opened '
          '(${request.error?.name}); a private window can refuse it',
        ),
      );
    }).toJS;
    request.onblocked = ((web.Event _) {
      opened.completeError(
        StateError('fespalier_keypair: IndexedDB is blocked by another tab'),
      );
    }).toJS;
    return opened.future;
  }
}

/// Fails the transaction a store call belongs to, once.
final class _Finish {
  _Finish(this._done);

  final Completer<void> _done;

  void error(web.DOMException? cause) {
    if (_done.isCompleted) return;
    _done.completeError(
      StateError(
        'fespalier_keypair: IndexedDB failed (${cause?.name}: ${cause?.message})',
      ),
    );
  }
}
