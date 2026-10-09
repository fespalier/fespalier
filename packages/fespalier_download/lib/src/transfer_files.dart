import 'transfer_files_stub.dart'
    if (dart.library.io) 'transfer_files_io.dart'
    as platform;

/// The files under a transfer (since 0.15.0): the port that `HttpTransfer` drives. Paths are
/// plain strings, so this library compiles for the web. The `dart:io` store is the default on
/// Android, iOS and the desktop; on the web the default answers [isSupported] false and every
/// call with an `UnsupportedError`, which a transfer reports as `Failed(unsupported)`.
/// `FakeTransferFiles` in `testing.dart` is the one for tests.
///
/// This is the path level of a transfer, with sinks, moves and a hash. The engine's own port is
/// `DownloadFiles`, which speaks `DownloadLocation`s; `TransferDownloadFiles` makes one from
/// this one.
abstract interface class TransferFiles {
  /// Whether this platform has files at all. False on the web: a transfer ends
  /// `Failed(unsupported)` before it makes a request.
  bool get isSupported;

  /// The size of the file at [path], or null when it is not there.
  Future<int?> length(String path);

  /// The text of the file at [path], or null when it is not there.
  Future<String?> readText(String path);

  /// Writes [text] to [path], replacing what is there and making the directory if needed.
  Future<void> writeText(String path, String text);

  /// Opens [path] for writing, making the directory if needed: appending to what is there when
  /// [append] is true, emptying it first when false.
  Future<TransferSink> open(String path, {required bool append});

  /// Moves [from] to [to], replacing [to]. On one volume this is atomic.
  Future<void> rename(String from, String to);

  /// Deletes [path]; a file that is not there is not an error.
  Future<void> delete(String path);

  /// The SHA-256 of the file at [path], as 64 lowercase hexadecimal digits.
  Future<String> sha256(String path);
}

/// A file open for writing, from [TransferFiles.open] (since 0.15.0).
abstract interface class TransferSink {
  /// Writes [chunk] and completes when it is on the file.
  Future<void> add(List<int> chunk);

  /// Flushes and closes the file.
  Future<void> close();
}

/// The files of this platform: `dart:io` where there is one, and a store that refuses every
/// call on the web (since 0.15.0).
TransferFiles defaultTransferFiles() => platform.defaultTransferFiles();
