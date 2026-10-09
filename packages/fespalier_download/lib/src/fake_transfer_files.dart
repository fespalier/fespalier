import 'package:crypto/crypto.dart' as crypto;

import 'transfer_files.dart';

/// A [TransferFiles] that is a map in memory, for tests of a transfer: no disk, and what a
/// transfer wrote is there for the test to read as it arrives (since 0.15.0).
///
/// Paths are plain keys. [rename] replaces the target; a file is found by [bytesOf] and
/// [textOf]. [failWrites], [failRename] and [failDelete] make that call throw, [unsupported]
/// makes every call throw an `UnsupportedError` the way the web's store does.
class FakeTransferFiles implements TransferFiles {
  /// An empty store. [files] and [texts] seed what an earlier session left.
  FakeTransferFiles({Map<String, List<int>>? files, Map<String, String>? texts})
    : _files = {
        for (final e in (files ?? const <String, List<int>>{}).entries)
          e.key: List<int>.of(e.value),
      },
      _texts = {...?texts};

  final Map<String, List<int>> _files;
  final Map<String, String> _texts;

  /// When set, [open] succeeds but the next [TransferSink.add] throws it.
  Object? failWrites;

  /// When set, [rename] throws it.
  Object? failRename;

  /// When set, [delete] throws it.
  Object? failDelete;

  /// Whether every call throws an `UnsupportedError` (the web).
  bool unsupported = false;

  /// The path of every file moved by [rename], as `from -> to`, in order.
  final List<String> renames = [];

  /// How many times [sha256] was asked for.
  int hashes = 0;

  /// The bytes at [path], or null when there is none.
  List<int>? bytesOf(String path) => _files[path];

  /// The text at [path], or null when there is none.
  String? textOf(String path) => _texts[path];

  /// Puts [bytes] at [path], as an earlier session left them.
  void putBytes(String path, List<int> bytes) =>
      _files[path] = List<int>.of(bytes);

  /// Puts [text] at [path].
  void putText(String path, String text) => _texts[path] = text;

  /// The paths of every file and text held, sorted.
  List<String> get paths => ([..._files.keys, ..._texts.keys]..sort());

  void _check() {
    if (unsupported) throw UnsupportedError('no files');
  }

  @override
  bool get isSupported => !unsupported;

  @override
  Future<int?> length(String path) async {
    _check();
    return _files[path]?.length;
  }

  @override
  Future<String?> readText(String path) async {
    _check();
    return _texts[path];
  }

  @override
  Future<void> writeText(String path, String text) async {
    _check();
    _texts[path] = text;
  }

  @override
  Future<TransferSink> open(String path, {required bool append}) async {
    _check();
    if (!append) _files[path] = [];
    final file = _files.putIfAbsent(path, () => []);
    return _FakeSink(this, file);
  }

  @override
  Future<void> rename(String from, String to) async {
    _check();
    final failure = failRename;
    if (failure != null) throw failure;
    final file = _files.remove(from);
    if (file == null) throw StateError('no file to rename');
    _files[to] = file;
    renames.add('$from -> $to');
  }

  @override
  Future<void> delete(String path) async {
    _check();
    final failure = failDelete;
    if (failure != null) throw failure;
    _files.remove(path);
    _texts.remove(path);
  }

  @override
  Future<String> sha256(String path) async {
    _check();
    hashes++;
    final file = _files[path];
    if (file == null) throw StateError('no file to hash');
    return crypto.sha256.convert(file).toString();
  }
}

final class _FakeSink implements TransferSink {
  _FakeSink(this._store, this._file);

  final FakeTransferFiles _store;
  final List<int> _file;

  @override
  Future<void> add(List<int> chunk) async {
    final failure = _store.failWrites;
    if (failure != null) throw failure;
    _file.addAll(chunk);
  }

  @override
  Future<void> close() async {}
}
