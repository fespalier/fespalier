import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the session is kept between runs (since 0.9.0): one string, `AuthSession.toJson`
/// encoded. `FutureOr`, so a store that answers at once keeps `restoreAuth` synchronous.
abstract interface class TokenStore {
  /// The stored session, or null.
  FutureOr<String?> read();

  /// Replaces the stored session with [value].
  FutureOr<void> write(String value);

  /// Forgets the stored session.
  FutureOr<void> delete();
}

/// In memory, and synchronous: tests, and the web when nothing should persist (a reload signs
/// the user out) (since 0.9.0).
final class MemoryTokenStore implements TokenStore {
  /// A store holding [value], nothing by default.
  MemoryTokenStore([this.value]);

  /// What is stored.
  String? value;

  @override
  String? read() => value;

  @override
  void write(String value) => this.value = value;

  @override
  void delete() => value = null;
}

/// `flutter_secure_storage`: the Keychain (`first_unlock_this_device`: not in backups, not on
/// another device), Android's encrypted storage and, on the web, encrypted `localStorage`, which
/// a script on the page can read (since 0.9.0).
final class SecureTokenStore implements TokenStore {
  /// A store under [key]. Pass a [storage] to change the platform options.
  const SecureTokenStore({
    this.key = 'fespalier_auth.session',
    this.storage = defaultStorage,
  });

  /// Keychain `first_unlock_this_device` on iOS and macOS, the plugin's defaults elsewhere.
  static const FlutterSecureStorage defaultStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  /// The storage key.
  final String key;

  /// The plugin.
  final FlutterSecureStorage storage;

  @override
  Future<String?> read() => storage.read(key: key);

  @override
  Future<void> write(String value) => storage.write(key: key, value: value);

  @override
  Future<void> delete() => storage.delete(key: key);
}
