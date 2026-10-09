import 'package:fespalier_download/fespalier_download.dart'
    show TransferFiles, TransferSink, defaultTransferFiles;

import 'store.dart';

/// The default [PackFileStore]: the files of fespalier_download for this platform (`dart:io`,
/// or a store that refuses every call on the web, which a download reports as
/// `Failed(unsupported)`).
PackFileStore defaultPackFileStore() => _PackFilesOver(defaultTransferFiles());

/// A [PackFileStore] seen as the [TransferFiles] that `HttpTransfer` drives. A store that
/// refuses with an `UnsupportedError` (the web's) is reported by the transfer as unsupported.
final class HttpTransferFiles implements TransferFiles {
  /// The transfer files over [files].
  const HttpTransferFiles(this._files);

  final PackFileStore _files;

  @override
  bool get isSupported => true;

  @override
  Future<int?> length(String path) => _files.length(path);

  @override
  Future<String?> readText(String path) => _files.readText(path);

  @override
  Future<void> writeText(String path, String text) =>
      _files.writeText(path, text);

  @override
  Future<TransferSink> open(String path, {required bool append}) async =>
      _SinkOver(await _files.open(path, append: append));

  @override
  Future<void> rename(String from, String to) => _files.rename(from, to);

  @override
  Future<void> delete(String path) => _files.delete(path);

  @override
  Future<String> sha256(String path) => _files.sha256(path);
}

final class _SinkOver implements TransferSink {
  _SinkOver(this._sink);

  final PackFileSink _sink;

  @override
  Future<void> add(List<int> chunk) => _sink.add(chunk);

  @override
  Future<void> close() => _sink.close();
}

// A TransferFiles seen as the PackFileStore the notifier holds.
final class _PackFilesOver implements PackFileStore {
  _PackFilesOver(this._files);

  final TransferFiles _files;

  @override
  Future<int?> length(String path) => _files.length(path);

  @override
  Future<String?> readText(String path) => _files.readText(path);

  @override
  Future<void> writeText(String path, String text) =>
      _files.writeText(path, text);

  @override
  Future<PackFileSink> open(String path, {required bool append}) async =>
      _PackSinkOver(await _files.open(path, append: append));

  @override
  Future<void> rename(String from, String to) => _files.rename(from, to);

  @override
  Future<void> delete(String path) => _files.delete(path);

  @override
  Future<String> sha256(String path) => _files.sha256(path);
}

final class _PackSinkOver implements PackFileSink {
  _PackSinkOver(this._sink);

  final TransferSink _sink;

  @override
  Future<void> add(List<int> chunk) => _sink.add(chunk);

  @override
  Future<void> close() => _sink.close();
}
