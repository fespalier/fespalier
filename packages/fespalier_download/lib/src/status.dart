import 'location.dart';

/// Why a download is [Waiting] (since 0.15.0).
enum WaitReason {
  /// There is no network.
  network,

  /// The request asks for an unmetered network and there is none.
  unmetered,

  /// An attempt failed and the backend will try again.
  retry,

  /// The backend runs as many downloads as it may, and this one is next.
  slot,
}

/// Why a download failed (since 0.15.0). A value, never an error's text.
enum DownloadFailure {
  /// This platform cannot download (the web).
  unsupported,

  /// The request was not valid.
  invalidRequest,

  /// The network failed.
  network,

  /// The server refused: an HTTP error that asking again will not fix.
  rejected,

  /// The server answered 401 or 403.
  unauthorized,

  /// The file has not the size the request said.
  sizeMismatch,

  /// The file has not the digest the request said.
  hashMismatch,

  /// The file could not be written.
  storage,

  /// A user-initiated download needs notifications and the app has none configured.
  notificationsRequired,

  /// The system stopped the download and it could not be resumed.
  killed,

  /// Anything else.
  other,
}

/// Where a download stands (since 0.15.0). Every `toString` prints the state and numbers only,
/// never a path.
sealed class DownloadStatus {
  const DownloadStatus();
}

/// No download is known with that id.
final class Absent extends DownloadStatus {
  /// Nothing known.
  const Absent();

  @override
  bool operator ==(Object other) => other is Absent;

  @override
  int get hashCode => (Absent).hashCode;

  @override
  String toString() => 'Absent';
}

/// Handed to the backend, not running yet.
final class Queued extends DownloadStatus {
  /// Queued.
  const Queued();

  @override
  bool operator ==(Object other) => other is Queued;

  @override
  int get hashCode => (Queued).hashCode;

  @override
  String toString() => 'Queued';
}

/// Not running, for a [reason].
final class Waiting extends DownloadStatus {
  /// Waiting for [reason].
  const Waiting(this.reason);

  /// What it waits for.
  final WaitReason reason;

  @override
  bool operator ==(Object other) => other is Waiting && other.reason == reason;

  @override
  int get hashCode => Object.hash(Waiting, reason);

  @override
  String toString() => 'Waiting(${reason.name})';
}

/// Transferring.
final class Running extends DownloadStatus {
  /// Running, with [received] bytes so far out of [total] (null when the server did not say).
  const Running(this.received, [this.total]);

  /// Bytes written so far.
  final int received;

  /// The size, when known.
  final int? total;

  @override
  bool operator ==(Object other) =>
      other is Running && other.received == received && other.total == total;

  @override
  int get hashCode => Object.hash(Running, received, total);

  @override
  String toString() => 'Running($received/${total ?? '?'})';
}

/// Stopped on purpose, with what was received kept for a later resume.
final class Paused extends DownloadStatus {
  /// Paused at [received] bytes out of [total].
  const Paused(this.received, [this.total]);

  /// Bytes kept.
  final int received;

  /// The size, when known.
  final int? total;

  @override
  bool operator ==(Object other) =>
      other is Paused && other.received == received && other.total == total;

  @override
  int get hashCode => Object.hash(Paused, received, total);

  @override
  String toString() => 'Paused($received/${total ?? '?'})';
}

/// Received; the size and the digest are being checked.
final class Verifying extends DownloadStatus {
  /// Verifying.
  const Verifying();

  @override
  bool operator ==(Object other) => other is Verifying;

  @override
  int get hashCode => (Verifying).hashCode;

  @override
  String toString() => 'Verifying';
}

/// Done: the file is in place and checked.
final class Complete extends DownloadStatus {
  /// Complete: [file] holds [bytes] bytes.
  const Complete(this.file, this.bytes);

  /// Where the file is.
  final DownloadLocation file;

  /// Its size.
  final int bytes;

  @override
  bool operator ==(Object other) =>
      other is Complete && other.file == file && other.bytes == bytes;

  @override
  int get hashCode => Object.hash(Complete, file, bytes);

  @override
  String toString() => 'Complete($bytes bytes)';
}

/// Ended without a file.
final class Failed extends DownloadStatus {
  /// Failed for [failure].
  const Failed(this.failure);

  /// Why.
  final DownloadFailure failure;

  @override
  bool operator ==(Object other) => other is Failed && other.failure == failure;

  @override
  int get hashCode => Object.hash(Failed, failure);

  @override
  String toString() => 'Failed(${failure.name})';
}

/// Stopped for good by the app; nothing kept.
final class Cancelled extends DownloadStatus {
  /// Cancelled.
  const Cancelled();

  @override
  bool operator ==(Object other) => other is Cancelled;

  @override
  int get hashCode => (Cancelled).hashCode;

  @override
  String toString() => 'Cancelled';
}
