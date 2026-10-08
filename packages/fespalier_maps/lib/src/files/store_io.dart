import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'store.dart';

/// The `dart:io` store.
PackFileStore defaultPackFileStore() => const _IoFiles();

final class _IoFiles implements PackFileStore {
  const _IoFiles();

  @override
  Future<int?> length(String path) async {
    final file = File(path);
    return await file.exists() ? file.length() : null;
  }

  @override
  Future<String?> readText(String path) async {
    final file = File(path);
    return await file.exists() ? file.readAsString() : null;
  }

  @override
  Future<void> writeText(String path, String text) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(text, flush: true);
  }

  @override
  Future<PackFileSink> open(String path, {required bool append}) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final handle = await file.open(
      mode: append ? FileMode.append : FileMode.write,
    );
    return _IoSink(handle);
  }

  @override
  Future<void> rename(String from, String to) async {
    await File(from).rename(to);
  }

  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<String> sha256(String path) async {
    final digest = await crypto.sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }
}

final class _IoSink implements PackFileSink {
  _IoSink(this._file);

  final RandomAccessFile _file;

  @override
  Future<void> add(List<int> chunk) async {
    await _file.writeFrom(chunk);
  }

  @override
  Future<void> close() async {
    await _file.flush();
    await _file.close();
  }
}
