import 'dart:convert';

import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:fespalier_download_background/fespalier_download_background.dart';
import 'package:flutter_test/flutter_test.dart';

const _file = '/data/fespalier_uploads.json';

Future<String> _bases(DownloadBase base) async => '/data';

UploadRequest req(
  String id, {
  UploadEncoding encoding = UploadEncoding.multipart,
  Map<String, String> fields = const {},
}) => UploadRequest(
  id: id,
  url: Uri.parse('https://api.example.com/$id'),
  file: DownloadLocation(DownloadBase.documents, 'outbox/$id.jpg'),
  method: UploadMethod.put,
  encoding: encoding,
  fileField: 'avatar',
  fields: fields,
  headers: const {'Idempotency-Key': 'k'},
  network: DownloadNetwork.unmetered,
  priority: DownloadPriority.userInitiated,
  displayName: 'Name $id',
);

FileUploadStore store(FakeTransferFiles files) =>
    FileUploadStore(bases: _bases, files: files);

void main() {
  test('a request survives a write and a new store, field by field', () async {
    final files = FakeTransferFiles();
    await store(files)
        .put(StoredUpload(req('a', fields: {'who': '7'}), generation: 3));
    await store(files)
        .put(StoredUpload(req('b', encoding: UploadEncoding.binary)));
    final loaded = await store(files).load();
    expect(loaded.keys, unorderedEquals(['a', 'b']));
    final a = loaded['a']!;
    expect(a.generation, 3);
    expect(a.request.url, Uri.parse('https://api.example.com/a'));
    expect(
      a.request.file,
      const DownloadLocation(DownloadBase.documents, 'outbox/a.jpg'),
    );
    expect(a.request.method, UploadMethod.put);
    expect(a.request.encoding, UploadEncoding.multipart);
    expect(a.request.fileField, 'avatar');
    expect(a.request.fields, {'who': '7'});
    expect(a.request.headers, {'Idempotency-Key': 'k'});
    expect(a.request.replaySafe, isTrue);
    expect(a.request.network, DownloadNetwork.unmetered);
    expect(a.request.priority, DownloadPriority.userInitiated);
    expect(a.request.displayName, 'Name a');
    expect(loaded['b']!.request.encoding, UploadEncoding.binary);
  });

  test('its file is not the downloads\' file', () async {
    final files = FakeTransferFiles();
    await store(files).put(StoredUpload(req('a')));
    expect(files.bytesOf(_file) ?? files.textOf(_file), isNotNull);
    expect(files.textOf('/data/fespalier_downloads.json'), isNull);
  });

  test('remove and clear drop entries; clear deletes the file', () async {
    final files = FakeTransferFiles();
    final s = store(files);
    await s.put(StoredUpload(req('a')));
    await s.put(StoredUpload(req('b')));
    await s.remove('a');
    expect((await store(files).load()).keys, ['b']);
    await s.clear();
    expect(await s.load(), isEmpty);
    expect(files.textOf(_file), isNull);
  });

  test('nothing is evicted, however many entries', () async {
    final files = FakeTransferFiles();
    final s = store(files);
    for (var i = 0; i < 300; i++) {
      await s.put(StoredUpload(req('u$i')));
    }
    expect((await store(files).load()), hasLength(300));
  });

  test('a corrupt or unknown file is an empty registry, an invalid entry is skipped', () async {
    final files = FakeTransferFiles()..putText(_file, '{not json');
    expect(await store(files).load(), isEmpty);
    files.putText(_file, jsonEncode({'v': 99, 'uploads': <String, Object?>{}}));
    expect(await store(files).load(), isEmpty);
    files.putText(
      _file,
      jsonEncode({
        'v': 1,
        'uploads': {
          'bad': {'url': 'ftp://x', 'base': 'support', 'path': '../x'},
          'ok': {
            'url': 'https://api.example.com/ok',
            'base': 'support',
            'path': 'a.bin',
            'method': 'post',
            'encoding': 'binary',
            'fileField': 'file',
            'network': 'any',
            'priority': 'background',
          },
        },
      }),
    );
    final loaded = await store(files).load();
    expect(loaded.keys, ['ok']);
    expect(loaded['ok']!.request.replaySafe, isFalse);
  });
}
