import 'dart:convert';

import 'package:fespalier_download/fespalier_download.dart';

import 'upload_ports.dart';
import 'upload_request.dart';

/// The durable registry of uploads as one JSON file (since 0.15.0), the sibling of
/// `FileDownloadStore` with the same guarantees: **not a cache** (nothing is evicted, and only
/// [remove] and [clear], which `Uploads.clearAccount` calls, drop an entry), every change rewrites
/// the whole file by atomic rename (`<name>.tmp`, then a move), writes are queued in order, a
/// missing or corrupt file is an empty registry, an entry that is not valid is skipped, and a
/// write that fails leaves the list in memory right for this run.
///
/// The file lives under a [DownloadBase] folder the app's [DownloadBases] resolves, by default
/// `support/fespalier_uploads.json`: a different file from the downloads', so the two registries
/// never meet. **A request's headers and fields are kept in plaintext.** Never a long-lived
/// credential or a refresh token in them. On the web the registry is in memory only.
class FileUploadStore implements UploadStore {
  /// A registry file under [base], resolved by `bases`. [files] is for tests
  /// (`FakeTransferFiles`); the default is `dart:io`.
  FileUploadStore({
    required this._bases,
    this.base = DownloadBase.support,
    this.name = 'fespalier_uploads.json',
    TransferFiles? files,
  }) : _files = files ?? defaultTransferFiles();

  /// The folder the file is in.
  final DownloadBase base;

  /// The file's name inside [base].
  final String name;

  final DownloadBases _bases;
  final TransferFiles _files;

  Map<String, StoredUpload>? _entries;
  Future<void> _tail = Future<void>.value();

  Future<String> _path() async => '${await _bases(base)}/$name';

  @override
  Future<Map<String, StoredUpload>> load() => _enqueue(() async {
    return {...await _ensureLoaded()};
  });

  @override
  Future<void> put(StoredUpload upload) => _enqueue(() async {
    (await _ensureLoaded())[upload.request.id] = upload;
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

  Future<Map<String, StoredUpload>> _ensureLoaded() async {
    final loaded = _entries;
    if (loaded != null) return loaded;
    final entries = <String, StoredUpload>{};
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

String _encode(Map<String, StoredUpload> entries) => jsonEncode({
  'v': _version,
  'uploads': {for (final e in entries.entries) e.key: _entryToJson(e.value)},
});

Map<String, Object?> _entryToJson(StoredUpload u) {
  final r = u.request;
  return {
    'generation': u.generation,
    'url': r.url.toString(),
    'base': r.file.base.name,
    'path': r.file.path,
    'method': r.method.name,
    'encoding': r.encoding.name,
    'fileField': r.fileField,
    if (r.fields.isNotEmpty) 'fields': r.fields,
    if (r.headers.isNotEmpty) 'headers': r.headers,
    'network': r.network.name,
    'priority': r.priority.name,
    if (r.displayName != null) 'displayName': r.displayName,
  };
}

Map<String, StoredUpload> _decode(String text) {
  final root = jsonDecode(text);
  if (root is! Map || root['v'] != _version) return {};
  final uploads = root['uploads'];
  if (uploads is! Map) return {};
  final out = <String, StoredUpload>{};
  for (final e in uploads.entries) {
    final id = e.key;
    final value = e.value;
    if (id is! String || value is! Map) continue;
    try {
      final request = UploadRequest(
        id: id,
        url: Uri.parse(value['url'] as String),
        file: DownloadLocation(
          DownloadBase.values.byName(value['base'] as String),
          value['path'] as String,
        ),
        method: UploadMethod.values.byName(value['method'] as String),
        encoding: UploadEncoding.values.byName(value['encoding'] as String),
        fileField: value['fileField'] as String,
        fields: {
          for (final f in ((value['fields'] as Map?) ?? const {}).entries)
            f.key as String: f.value as String,
        },
        headers: {
          for (final h in ((value['headers'] as Map?) ?? const {}).entries)
            h.key as String: h.value as String,
        },
        network: DownloadNetwork.values.byName(value['network'] as String),
        priority: DownloadPriority.values.byName(value['priority'] as String),
        displayName: value['displayName'] as String?,
      );
      if (!request.isValid) continue;
      out[id] = StoredUpload(
        request,
        generation: (value['generation'] as int?) ?? 0,
      );
    } catch (_) {
      continue;
    }
  }
  return out;
}
