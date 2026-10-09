/// Fakes for testing downloads with no network, no platform and no disk (since 0.15.0):
/// `FakeDownloadBackend`, `MemoryDownloadStore` and `FakeDownloadFiles`.
library;

import 'fespalier_download.dart';

/// A [DownloadBackend] that does nothing by itself: the test plays the platform through
/// [emit] and [tap], and reads what the engine asked from the lists.
class FakeDownloadBackend implements DownloadBackend {
  /// A fake. [capabilities] is what it claims; [accepts] decides whether [enqueue] succeeds.
  FakeDownloadBackend({
    this.capabilities = const DownloadCapabilities(pause: true),
    this.accepts = true,
  });

  @override
  final DownloadCapabilities capabilities;

  /// Whether [enqueue] and [resume] answer true.
  bool accepts;

  DownloadEvents? _events;

  /// Whether [open] was called and [close] was not.
  bool get isOpen => _events != null;

  /// Every request handed to [enqueue], in order.
  final List<DownloadRequest> enqueued = [];

  /// The `authorization` of each [enqueue] and [resume], in order.
  final List<Map<String, String>> authorizations = [];

  /// The ids passed to [pause], in order.
  final List<String> paused = [];

  /// The ids passed to [resume], in order.
  final List<String> resumed = [];

  /// The ids passed to [cancel], in order.
  final List<String> cancelled = [];

  /// How many times [cancelAll] was called.
  int cancelAllCalls = 0;

  /// The last texts passed to [configureNotifications].
  DownloadNotifications? notifications;

  /// Reports that the download [id] is in [status], as the platform would.
  void emit(String id, DownloadStatus status, {int? httpStatus}) {
    final events = _events;
    if (events == null) {
      throw StateError('FakeDownloadBackend.emit before open()');
    }
    events.status(id, status, httpStatus: httpStatus);
  }

  /// Reports a tap on the notification of the download [id].
  void tap(String id, [DownloadTapKind kind = DownloadTapKind.body]) {
    final events = _events;
    if (events == null) {
      throw StateError('FakeDownloadBackend.tap before open()');
    }
    events.tapped(id, kind);
  }

  @override
  Future<void> open(DownloadEvents events) async {
    _events = events;
  }

  @override
  Future<void> close() async {
    _events = null;
  }

  @override
  Future<bool> enqueue(
    DownloadRequest request, {
    Map<String, String> authorization = const {},
  }) async {
    enqueued.add(request);
    authorizations.add(authorization);
    return accepts;
  }

  @override
  Future<bool> pause(String id) async {
    paused.add(id);
    return capabilities.pause;
  }

  @override
  Future<bool> resume(
    String id, {
    Map<String, String> authorization = const {},
  }) async {
    resumed.add(id);
    authorizations.add(authorization);
    return capabilities.pause && accepts;
  }

  @override
  Future<void> cancel(String id) async {
    cancelled.add(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
  }

  @override
  Future<String> resolve(DownloadLocation location) async =>
      '/fake/${location.base.name}/${location.path}';

  @override
  Future<void> configureNotifications(DownloadNotifications? value) async {
    notifications = value;
  }
}

/// A [DownloadStore] in memory: nothing is evicted, and a [load] returns a copy.
class MemoryDownloadStore implements DownloadStore {
  /// A store holding [initial].
  MemoryDownloadStore([Map<String, StoredDownload> initial = const {}])
    : entries = {...initial};

  /// What the store holds right now.
  final Map<String, StoredDownload> entries;

  /// How many times [clear] was called.
  int clearCalls = 0;

  @override
  Future<Map<String, StoredDownload>> load() async => {...entries};

  @override
  Future<void> put(StoredDownload download) async {
    entries[download.request.id] = download;
  }

  @override
  Future<void> remove(String id) async {
    entries.remove(id);
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    entries.clear();
  }
}

/// A [DownloadFiles] over a map of sizes, with no disk.
class FakeDownloadFiles implements DownloadFiles {
  /// Files that already exist, by location, with their sizes.
  FakeDownloadFiles([Map<DownloadLocation, int> initial = const {}])
    : sizes = {...initial};

  /// The size of each file that exists.
  final Map<DownloadLocation, int> sizes;

  /// The locations passed to [delete], in order.
  final List<DownloadLocation> deleted = [];

  /// Makes a file of [bytes] bytes appear at [location], as a finished transfer would.
  void put(DownloadLocation location, int bytes) {
    sizes[location] = bytes;
  }

  @override
  Future<bool> exists(DownloadLocation location) async =>
      sizes.containsKey(location);

  @override
  Future<int?> length(DownloadLocation location) async => sizes[location];

  @override
  Future<void> delete(DownloadLocation location) async {
    deleted.add(location);
    sizes.remove(location);
  }
}
