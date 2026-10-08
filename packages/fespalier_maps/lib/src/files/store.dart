/// The files under file packs: the port that `FilePacks` drives (since 0.13.0). The `dart:io`
/// one is the default on Android and iOS; on the web the default answers `UnsupportedError` to
/// every call, which `FilePacks` reports as `Failed(unsupported)`. `FakePackFiles` in
/// `testing.dart` is the one for tests.
///
/// Paths are plain strings so that this library compiles for the web.
abstract interface class PackFileStore {
  /// The size of the file at [path], or null when it is not there.
  Future<int?> length(String path);

  /// The text of the file at [path], or null when it is not there.
  Future<String?> readText(String path);

  /// Writes [text] to [path], replacing what is there and making the directory if needed.
  Future<void> writeText(String path, String text);

  /// Opens [path] for writing, making the directory if needed: appending to what is there when
  /// [append] is true, emptying it first when false.
  Future<PackFileSink> open(String path, {required bool append});

  /// Moves [from] to [to], replacing [to]. On one volume this is atomic.
  Future<void> rename(String from, String to);

  /// Deletes [path]; a file that is not there is not an error.
  Future<void> delete(String path);

  /// The SHA-256 of the file at [path], as 64 lowercase hexadecimal digits.
  Future<String> sha256(String path);
}

/// A file open for writing, from [PackFileStore.open].
abstract interface class PackFileSink {
  /// Writes [chunk] and completes when it is on the file.
  Future<void> add(List<int> chunk);

  /// Flushes and closes the file.
  Future<void> close();
}
