// The browser's key, run in a browser: `flutter test --platform chrome test/web_crypto_signer_test.dart`.
// No CI job of this repository does that, so these tests are UNCHECKED IN CI; they were run by hand
// in Chrome (DDC, and `--wasm`) and passed (see the package README).
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'support.dart';

Future<web.IDBDatabase> _openDatabase() {
  final done = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open('fespalier_keypair', 1);
  request.onupgradeneeded = ((web.Event _) {
    (request.result! as web.IDBDatabase).createObjectStore('keys');
  }).toJS;
  request.onsuccess = ((web.Event _) {
    done.complete(request.result! as web.IDBDatabase);
  }).toJS;
  request.onerror = ((web.Event _) => done.completeError('open failed')).toJS;
  return done.future;
}

/// The raw record under [keyId], as the browser stores it.
Future<JSObject?> _record(String keyId) async {
  final database = await _openDatabase();
  final done = Completer<JSObject?>();
  final request = database
      .transaction('keys'.toJS, 'readonly')
      .objectStore('keys')
      .get(keyId.toJS);
  request.onsuccess = ((web.Event _) {
    done.complete(request.result as JSObject?);
  }).toJS;
  final record = await done.future;
  database.close();
  return record;
}

void main() {
  var counter = 0;
  String freshId() =>
      'test_key_${DateTime.now().microsecondsSinceEpoch}_${counter++}';

  test('the browser here can hold the key', () {
    expect(WebCryptoKeypairSigner.isSupported, isTrue);
  });

  test(
    'makes a P-256 key on first use, ambient, and signs a 64-byte r||s signature that verifies',
    () async {
      final signer = WebCryptoKeypairSigner(keyId: freshId());
      addTearDown(signer.deleteKey);
      expect(signer.role, KeyRole.ambient);
      final jwk = await signer.publicJwk();
      expect(jwk.keys, ['crv', 'kty', 'x', 'y']);
      expect(jwk['kty'], 'EC');
      expect(jwk['crv'], 'P-256');
      expect(base64UrlDecodeLoose(jwk['x']!), hasLength(32));
      expect(base64UrlDecodeLoose(jwk['y']!), hasLength(32));
      final input = Uint8List.fromList(List<int>.generate(40, (i) => i));
      final signature = await signer.sign(input);
      expect(signature, hasLength(64));
      expect(verifiesEs256(jwk, input, signature), isTrue);
      expect(verifiesEs256(jwk, [...input, 1], signature), isFalse);
      expect(await signer.isHardwareBacked(), isFalse);
    },
  );

  test('exists asks without making the key', () async {
    final signer = WebCryptoKeypairSigner(keyId: freshId());
    addTearDown(signer.deleteKey);
    expect(await signer.exists(), isFalse);
    expect(await signer.exists(), isFalse, reason: 'asking made nothing');
    await signer.publicJwk();
    expect(await signer.exists(), isTrue);
  });

  test(
    'survives a reload: a new signer for the same key id finds the same key',
    () async {
      final id = freshId();
      final first = WebCryptoKeypairSigner(keyId: id);
      addTearDown(first.deleteKey);
      final jwk = await first.publicJwk();
      final input = Uint8List.fromList([1, 2, 3]);
      final again = WebCryptoKeypairSigner(keyId: id);
      expect(await again.exists(), isTrue);
      expect(await again.publicJwk(), jwk);
      expect(verifiesEs256(jwk, input, await again.sign(input)), isTrue);
    },
  );

  test('two first uses at once make one key', () async {
    final signer = WebCryptoKeypairSigner(keyId: freshId());
    addTearDown(signer.deleteKey);
    final results = await Future.wait([signer.publicJwk(), signer.publicJwk()]);
    expect(results[0], results[1]);
    // And two signers (two tabs) that arrive together agree on the one that was stored first.
    final id = freshId();
    final a = WebCryptoKeypairSigner(keyId: id);
    final b = WebCryptoKeypairSigner(keyId: id);
    addTearDown(a.deleteKey);
    final both = await Future.wait([a.publicJwk(), b.publicJwk()]);
    expect(both[0], both[1]);
    expect(await WebCryptoKeypairSigner(keyId: id).publicJwk(), both[0]);
  });

  test('different key ids are different keys', () async {
    final a = WebCryptoKeypairSigner(keyId: freshId());
    final b = WebCryptoKeypairSigner(keyId: freshId());
    addTearDown(a.deleteKey);
    addTearDown(b.deleteKey);
    expect(await a.publicJwk(), isNot(await b.publicJwk()));
  });

  test('deleteKey deletes it, and the next use makes a new one', () async {
    final signer = WebCryptoKeypairSigner(keyId: freshId());
    addTearDown(signer.deleteKey);
    final first = await signer.publicJwk();
    await signer.deleteKey();
    expect(await signer.exists(), isFalse);
    final second = await signer.publicJwk();
    expect(second, isNot(first));
  });

  test(
    'the private key is not extractable: the browser refuses to export it',
    () async {
      final id = freshId();
      final signer = WebCryptoKeypairSigner(keyId: id);
      addTearDown(signer.deleteKey);
      await signer.publicJwk();
      final record = await _record(id);
      expect(record, isNotNull);
      final privateKey = record!.getProperty<web.CryptoKey>('privateKey'.toJS);
      expect(privateKey.extractable, isFalse);
      await expectLater(
        web.window.crypto.subtle.exportKey('jwk', privateKey).toDart,
        throwsA(anything),
      );
      expect(privateKey.type, 'private');
    },
  );

  test('a user-present key is refused, not faked', () {
    expect(
      () => WebCryptoKeypairSigner(keyId: 'x', role: KeyRole.userPresent),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('no user-present key'),
        ),
      ),
    );
  });

  test('KeypairSigners.device picks it on the web', () {
    expect(
      KeypairSigners.device(keyId: freshId()),
      isA<WebCryptoKeypairSigner>(),
    );
    expect(
      () => KeypairSigners.device(keyId: 'x', role: KeyRole.userPresent),
      throwsA(isA<KeypairUnavailable>()),
    );
  });
}
