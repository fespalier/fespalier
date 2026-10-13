import 'dart:convert';

import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:fespalier_download_background/fespalier_download_background.dart';
import 'package:fespalier_download_background/testing.dart';
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

  test('an entry that is not valid is skipped, the rest is kept', () async {
    final files = FakeTransferFiles()
      ..putText(
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

  test('a missing file is an empty registry', () async {
    expect(await store(FakeTransferFiles()).load(), isEmpty);
  });

  group('a registry that cannot be trusted is not an empty one', () {
    // The registry remembers which uploads may have been sent. Read as empty and written over,
    // it would forget them, and `start` would send them again with nothing to say they were sent.
    for (final (label, text) in [
      ('not JSON', '{not json'),
      ('an empty file', ''),
      ('a version this one does not know', '{"v":99,"uploads":{}}'),
      ('a root that is no map', '[]'),
      ('no uploads map', '{"v":1}'),
    ]) {
      test(
        '$label: load throws, put throws, the file is not overwritten',
        () async {
          final files = FakeTransferFiles()..putText(_file, text);
          final s = store(files);
          await expectLater(s.load(), throwsA(isA<UploadStoreException>()));
          await expectLater(
            s.put(StoredUpload(req('a'))),
            throwsA(isA<UploadStoreException>()),
          );
          expect(
            files.textOf(_file),
            text,
            reason: 'what is there is kept for a person to look at',
          );
          expect(files.paths, [_file], reason: 'no temporary file is left');
        },
      );
    }

    test(
      'a read that fails is not cached as empty: the next call reads again',
      () async {
        final files = _Flaky()..putText(_file, _oneEntry('kept'));
        final s = store(files);
        files.failRead = StateError('I/O');
        await expectLater(s.load(), throwsA(isA<UploadStoreException>()));
        await expectLater(
          s.put(StoredUpload(req('new'))),
          throwsA(isA<UploadStoreException>()),
        );
        files.failRead = null;
        expect((await s.load()).keys, ['kept']);
        await s.put(StoredUpload(req('new')));
        expect(
          (await store(files).load()).keys,
          unorderedEquals(['kept', 'new']),
        );
      },
    );

    test(
      'clear repairs it: the file goes and the registry is empty and usable',
      () async {
        final files = FakeTransferFiles()..putText(_file, '{not json');
        final s = store(files);
        await s.clear();
        expect(await s.load(), isEmpty);
        await s.put(StoredUpload(req('a')));
        expect((await store(files).load()).keys, ['a']);
      },
    );

    test(
      'an unsupported platform (the web) is memory only, as before',
      () async {
        final files = FakeTransferFiles()..unsupported = true;
        final s = store(files);
        await s.put(StoredUpload(req('a')));
        expect((await s.load()).keys, ['a']);
      },
    );
  });

  group('an entry that cannot be written', () {
    test('put throws, and the entry is not in the registry', () async {
      final files = _Flaky();
      final s = store(files);
      await s.put(StoredUpload(req('a')));
      files.failWriteText = StateError('disk full');
      await expectLater(
        s.put(StoredUpload(req('b'))),
        throwsA(isA<UploadStoreException>()),
      );
      expect((await s.load()).keys, [
        'a',
      ], reason: 'memory says what the disk says');
      files.failWriteText = null;
      expect((await store(files).load()).keys, ['a']);
    });

    test('a failed rename is the same, and the old file stays whole', () async {
      final files = FakeTransferFiles();
      final s = store(files);
      await s.put(StoredUpload(req('a')));
      files.failRename = StateError('x');
      await expectLater(
        s.put(StoredUpload(req('b'))),
        throwsA(isA<UploadStoreException>()),
      );
      files.failRename = null;
      expect((await store(files).load()).keys, ['a']);
    });

    test(
      'replacing an entry that cannot be written keeps the earlier one',
      () async {
        final files = _Flaky();
        final s = store(files);
        await s.put(StoredUpload(req('a'), generation: 1));
        files.failWriteText = StateError('disk full');
        await expectLater(
          s.put(StoredUpload(req('a'), generation: 2)),
          throwsA(isA<UploadStoreException>()),
        );
        expect((await s.load())['a']!.generation, 1);
      },
    );

    test('a remove that cannot be written still removes it in memory, and does not throw', () async {
      final files = _Flaky();
      final s = store(files);
      await s.put(StoredUpload(req('a')));
      files.failWriteText = StateError('disk full');
      await s.remove('a');
      expect(await s.load(), isEmpty);
    });
  });

  test('the exception prints its constant text and nothing else', () {
    const e = UploadStoreException('the registry file could not be written');
    expect(
      e.toString(),
      'UploadStoreException: the registry file could not be written',
    );
  });

  test('a registry that cannot be saved: the engine sends nothing, Failed(storage)', () async {
    final files = _Flaky()..failWriteText = StateError('disk full');
    final backend = FakeUploadBackend(
      capabilities: const DownloadCapabilities(notifications: true),
    );
    final engine = Uploads(backend: backend, store: store(files));
    await engine.open();
    await engine.start(req('a'));
    expect(engine.statusOf('a'), const Failed(DownloadFailure.storage));
    expect(backend.enqueued, isEmpty);
  });

  test('after a restart, a registry that cannot be read does not start an upload without a key', () async {
    final files = _Flaky()..putText(_file, _oneEntry('kept'));
    files.failRead = StateError('I/O');
    final backend = FakeUploadBackend();
    final engine = Uploads(backend: backend, store: store(files));
    await engine.open();
    await engine.start(
      UploadRequest(
        id: 'kept',
        url: Uri.parse('https://api.example.com/kept'),
        file: const DownloadLocation(DownloadBase.documents, 'outbox/kept.jpg'),
      ),
    );
    expect(engine.statusOf('kept'), const Failed(DownloadFailure.storage));
    expect(backend.enqueued, isEmpty);
    expect(
      files.textOf(_file),
      _oneEntry('kept'),
      reason: 'the record is still there',
    );
  });
}

String _oneEntry(String id) => jsonEncode({
  'v': 1,
  'uploads': {
    id: {
      'url': 'https://api.example.com/$id',
      'base': 'documents',
      'path': 'outbox/$id.jpg',
      'method': 'post',
      'encoding': 'multipart',
      'fileField': 'file',
      'network': 'any',
      'priority': 'background',
    },
  },
});

/// Files that fail on a read or a text write when told to.
class _Flaky extends FakeTransferFiles {
  Object? failRead;
  Object? failWriteText;

  @override
  Future<String?> readText(String path) async {
    final failure = failRead;
    if (failure != null) throw failure;
    return super.readText(path);
  }

  @override
  Future<void> writeText(String path, String text) async {
    final failure = failWriteText;
    if (failure != null) throw failure;
    return super.writeText(path, text);
  }
}
