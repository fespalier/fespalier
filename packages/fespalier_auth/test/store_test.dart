// The token stores: the memory one is synchronous end to end, the secure one is the plugin's.
import 'dart:async';

import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemoryTokenStore', () {
    test('answers synchronously: read is not a Future', () {
      final store = MemoryTokenStore();
      expect(store.read(), isNull);
      expect(store.read(), isNot(isA<Future<Object?>>()));
      store.write('one');
      expect(store.read(), 'one');
      expect(store.value, 'one');
      store.delete();
      expect(store.read(), isNull);
    });

    test('holds what it was given', () {
      expect(MemoryTokenStore('x').read(), 'x');
    });

    test('is a TokenStore whose answers are FutureOr', () {
      final TokenStore store = MemoryTokenStore('x');
      final FutureOr<String?> value = store.read();
      expect(value, isNot(isA<Future<Object?>>()));
    });
  });

  group('SecureTokenStore', () {
    test('reads, writes and deletes under its key, on the plugin', () async {
      final data = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(data);
      const store = SecureTokenStore();
      expect(await store.read(), isNull);
      await store.write('session');
      expect(data, {'fespalier_auth.session': 'session'});
      expect(await store.read(), 'session');
      await store.delete();
      expect(data, isEmpty);
    });

    test('a key of its own', () async {
      final data = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(data);
      await const SecureTokenStore(key: 'shop.session').write('x');
      expect(data.keys, ['shop.session']);
    });

    test('is the answer of an async read: a Future', () {
      FlutterSecureStorage.setMockInitialValues({});
      expect(const SecureTokenStore().read(), isA<Future<String?>>());
    });

    test(
      'the default storage is const: the Keychain is first_unlock_this_device',
      () {
        expect(
          SecureTokenStore.defaultStorage.iOptions.accessibility,
          KeychainAccessibility.first_unlock_this_device,
        );
        expect(
          SecureTokenStore.defaultStorage.mOptions.accessibility,
          KeychainAccessibility.first_unlock_this_device,
        );
        expect(
          identical(
            const SecureTokenStore().storage,
            SecureTokenStore.defaultStorage,
          ),
          isTrue,
        );
      },
    );
  });
}
