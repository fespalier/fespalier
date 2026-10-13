import 'dart:convert';

import 'http_backend.dart';
import 'location.dart';
import 'ports.dart';
import 'request.dart';
import 'transfer_files.dart';

/// The durable registry of downloads as one JSON file (since 0.15.0): what the app asked for,
/// kept across restarts so the engine can settle each download when it opens.
///
/// It is **not a cache**: nothing is evicted (do not put it on a `BoundedDataStorage`, which drops
/// the oldest entries), and only [remove] and [clear] (`Downloads.clearAccount`) drop one.
///
/// The file lives under a [DownloadBase] folder the app's `DownloadBases` resolves (the same
/// function the backend uses, so this package needs no `path_provider`), by default
/// `support/fespalier_downloads.json`. Every change rewrites the whole file by **atomic
/// rename**: the new text goes to `<name>.tmp` and replaces the file in one move, so a crash
/// between the two leaves the previous file whole. Writes are queued in order.
///
/// A missing, unreadable or corrupt file is an empty registry and [load] never throws; an entry
/// that is not valid is skipped and the rest is kept. A write that fails (a full disk) is dropped
/// and the list in memory stays right for this run, so a download never fails because the
/// registry could not be saved.
///
/// **A request's headers are kept in this file in plaintext.** Never a long-lived credential or
/// a refresh token in a header; use a short-lived URL.
///
/// On the web (`TransferFiles.isSupported` false) the registry is in memory only: every start
/// ends `Failed(unsupported)` there anyway, so there is nothing to keep.
class FileDownloadStore implements DownloadStore {
  /// A registry file under [base], resolved by [bases]. [files] is for tests
  /// (`FakeTransferFiles`); the default is `dart:io`.
  FileDownloadStore({
    required DownloadBases bases,
    this.base = DownloadBase.support,
    this.name = 'fespalier_downloads.json',
    TransferFiles? files,
  }) : _bases = bases,
       _files = files ?? defaultTransferFiles();

  /// The folder the file is in.
  final DownloadBase base;

  /// The file's name inside [base].
  final String name;

  final DownloadBases _bases;
  final TransferFiles _files;

  Map<String, StoredDownload>? _entries;
  Future<void> _tail = Future<void>.value();

  Future<String> _path() async => '${await _bases(base)}/$name';

  @override
  Future<Map<String, StoredDownload>> load() => _enqueue(() async {
    return {...await _ensureLoaded()};
  });

  @override
  Future<void> put(StoredDownload download) => _enqueue(() async {
    (await _ensureLoaded())[download.request.id] = download;
    await _save();
  });

  @override
  Future<void> remove(String id) => _enqueue(() async {
    final entries = await _ensureLoaded();
    if (entries.remove(id) != null) await _save();
  });

  @override
  Future<void> clear() => _enqueue(() async {
    _entries = {};
    if (!_files.isSupported) return;
    try {
      final path = await _path();
      await _files.delete('$path.tmp');
      await _files.delete(path);
    } catch (_) {
      // Left behind, it would be read as the old list: write an empty one over it.
      await _save();
    }
  });

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final result = _tail.then((_) => job());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Map<String, StoredDownload>> _ensureLoaded() async {
    final loaded = _entries;
    if (loaded != null) return loaded;
    final entries = <String, StoredDownload>{};
    if (_files.isSupported) {
      try {
        final text = await _files.readText(await _path());
        if (text != null) entries.addAll(_decode(text));
      } catch (_) {
        // Unreadable is empty.
      }
    }
    return _entries = entries;
  }

  Future<void> _save() async {
    if (!_files.isSupported) return;
    try {
      final path = await _path();
      final text = _encode(_entries ?? const {});
      await _files.writeText('$path.tmp', text);
      await _files.rename('$path.tmp', path);
    } catch (_) {
      // The list in memory is right for this run; the next change writes it all again.
    }
  }
}

const int _version = 1;

String _encode(Map<String, StoredDownload> entries) => jsonEncode({
  'v': _version,
  'downloads': {for (final e in entries.entries) e.key: _entryToJson(e.value)},
});

Map<String, Object?> _entryToJson(StoredDownload d) {
  final r = d.request;
  return {
    'generation': d.generation,
    'url': r.url.toString(),
    'base': r.file.base.name,
    'path': r.file.path,
    if (r.headers.isNotEmpty) 'headers': r.headers,
    if (r.bytes != null) 'bytes': r.bytes,
    if (r.sha256 != null) 'sha256': r.sha256,
    'network': r.network.name,
    'priority': r.priority.name,
    if (r.displayName != null) 'displayName': r.displayName,
  };
}

/// The entries of [text], skipping each one that is not valid; throws on text that is not JSON
/// (the caller reads that as empty).
Map<String, StoredDownload> _decode(String text) {
  final root = jsonDecode(text);
  if (root is! Map || root['v'] != _version) return {};
  final downloads = root['downloads'];
  if (downloads is! Map) return {};
  final out = <String, StoredDownload>{};
  for (final e in downloads.entries) {
    final id = e.key;
    final value = e.value;
    if (id is! String || value is! Map) continue;
    try {
      final request = DownloadRequest(
        id: id,
        url: Uri.parse(value['url'] as String),
        file: DownloadLocation(
          DownloadBase.values.byName(value['base'] as String),
          value['path'] as String,
        ),
        headers: {
          for (final h in ((value['headers'] as Map?) ?? const {}).entries)
            h.key as String: h.value as String,
        },
        bytes: value['bytes'] as int?,
        sha256: value['sha256'] as String?,
        network: DownloadNetwork.values.byName(value['network'] as String),
        priority: DownloadPriority.values.byName(value['priority'] as String),
        displayName: value['displayName'] as String?,
      );
      if (!request.isValid) continue;
      out[id] = StoredDownload(
        request,
        generation: (value['generation'] as int?) ?? 0,
      );
    } catch (_) {
      continue;
    }
  }
  return out;
}
