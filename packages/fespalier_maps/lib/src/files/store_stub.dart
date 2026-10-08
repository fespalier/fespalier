import 'store.dart';

/// The store where there are no files (the web): every call is an `UnsupportedError`.
PackFileStore defaultPackFileStore() => const _NoFiles();

final class _NoFiles implements PackFileStore {
  const _NoFiles();

  static Never _no() =>
      throw UnsupportedError('file packs need dart:io: not on the web');

  @override
  Future<int?> length(String path) async => _no();

  @override
  Future<String?> readText(String path) async => _no();

  @override
  Future<void> writeText(String path, String text) async => _no();

  @override
  Future<PackFileSink> open(String path, {required bool append}) async => _no();

  @override
  Future<void> rename(String from, String to) async => _no();

  @override
  Future<void> delete(String path) async => _no();

  @override
  Future<String> sha256(String path) async => _no();
}
