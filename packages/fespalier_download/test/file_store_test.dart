import 'dart:convert';
import 'dart:io';

import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _file = '/data/fespalier_downloads.json';

Future<String> _bases(DownloadBase base) async => '/data';

DownloadRequest req(
  String id, {
  Map<String, String> headers = const {},
  DownloadPriority priority = DownloadPriority.background,
}) => DownloadRequest(
  id: id,
  url: Uri.parse('https://example.com/$id'),
  file: DownloadLocation(DownloadBase.cache, 'f/$id.bin'),
  headers: headers,
  bytes: 10,
  sha256: 'a' * 64,
  network: DownloadNetwork.unmetered,
  priority: priority,
  displayName: 'Name $id',
);

FileDownloadStore store(FakeTransferFiles files) =>
    FileDownloadStore(bases: _bases, files: files);

void main() {
  test('a request survives a write and a new store, field by field', () async {
    final files = FakeTransferFiles();
    final first = store(files);
    await first.put(
      StoredDownload(
        req(
          'a',
          headers: {'X-Key': 'v'},
          priority: DownloadPriority.userInitiated,
        ),
        generation: 3,
      ),
    );
    await first.put(StoredDownload(req('b')));

    final loaded = await store(files).load();
    expect(loaded.keys, unorderedEquals(['a', 'b']));
    final a = loaded['a']!;
    expect(a.generation, 3);
    expect(a.request.url, Uri.parse('https://example.com/a'));
    expect(
      a.request.file,
      const DownloadLocation(DownloadBase.cache, 'f/a.bin'),
    );
    expect(a.request.headers, {'X-Key': 'v'});
    expect(a.request.bytes, 10);
    expect(a.request.sha256, 'a' * 64);
    expect(a.request.network, DownloadNetwork.unmetered);
    expect(a.request.priority, DownloadPriority.userInitiated);
    expect(a.request.displayName, 'Name a');
    expect(loaded['b']!.generation, 0);
  });

  test('remove and clear drop entries; clear deletes the file', () async {
    final files = FakeTransferFiles();
    final s = store(files);
    await s.put(StoredDownload(req('a')));
    await s.put(StoredDownload(req('b')));
    await s.remove('a');
    expect((await store(files).load()).keys, ['b']);
    await s.clear();
    expect(files.textOf(_file), isNull);
    expect(files.textOf('$_file.tmp'), isNull);
    expect(await store(files).load(), isEmpty);
    // A put after a clear starts a fresh file.
    await s.put(StoredDownload(req('c')));
    expect((await store(files).load()).keys, ['c']);
  });

  test('nothing is evicted, however many entries', () async {
    final files = FakeTransferFiles();
    final s = store(files);
    for (var i = 0; i < 300; i++) {
      await s.put(StoredDownload(req('d$i')));
    }
    expect(await store(files).load(), hasLength(300));
  });

  test('every change goes through a temp file and a rename', () async {
    final files = FakeTransferFiles();
    await store(files).put(StoredDownload(req('a')));
    expect(files.renames, ['$_file.tmp -> $_file']);
    expect(files.textOf('$_file.tmp'), isNull);
    expect(jsonDecode(files.textOf(_file)!), containsPair('v', 1));
  });

  test(
    'a crash between the temp write and the rename leaves the old file valid',
    () async {
      final files = FakeTransferFiles();
      final s = store(files);
      await s.put(StoredDownload(req('a')));
      final before = files.textOf(_file);

      files.failRename = const FileSystemException('crash');
      await s.put(StoredDownload(req('b')));
      // The file is the old one, whole, and the half-done write is only the temp file.
      expect(files.textOf(_file), before);
      expect(files.textOf('$_file.tmp'), contains('"b"'));
      expect((await store(files).load()).keys, ['a']);

      // The next change after the disk recovers writes everything again.
      files.failRename = null;
      await s.put(StoredDownload(req('c')));
      expect(
        (await store(files).load()).keys,
        unorderedEquals(['a', 'b', 'c']),
      );
    },
  );

  test('a missing file is an empty registry', () async {
    expect(await store(FakeTransferFiles()).load(), isEmpty);
  });

  test('a corrupt file is an empty registry, and never throws', () async {
    for (final text in [
      '',
      '{',
      'not json',
      '[]',
      '{"v":2,"downloads":{}}',
      '{"v":1}',
      '{"v":1,"downloads":[]}',
    ]) {
      final files = FakeTransferFiles(texts: {_file: text});
      expect(await store(files).load(), isEmpty, reason: text);
      // It recovers: the next put replaces the bad file.
      final s = store(files);
      await s.put(StoredDownload(req('a')));
      expect((await store(files).load()).keys, ['a'], reason: text);
    }
  });

  test('an entry that is not valid is skipped and the rest is kept', () async {
    final good = {
      'url': 'https://example.com/ok',
      'base': 'support',
      'path': 'ok.bin',
      'network': 'any',
      'priority': 'background',
    };
    final files = FakeTransferFiles(
      texts: {
        _file: jsonEncode({
          'v': 1,
          'downloads': {
            'ok': good,
            'badBase': {...good, 'base': 'nowhere'},
            'traversal': {...good, 'path': '../x'},
            'notAMap': 5,
            'badUrl': {...good, 'url': 'file:///etc/passwd'},
            'noUrl': {'base': 'support'},
          },
        }),
      },
    );
    expect((await store(files).load()).keys, ['ok']);
  });

  test('where there are no files the registry lives in memory', () async {
    final files = FakeTransferFiles()..unsupported = true;
    final s = store(files);
    expect(await s.load(), isEmpty);
    await s.put(StoredDownload(req('a')));
    expect((await s.load()).keys, ['a']);
    expect(files.paths, isEmpty);
    await s.clear();
    expect(await s.load(), isEmpty);
  });

  test('concurrent changes are written in order, none lost', () async {
    final files = FakeTransferFiles();
    final s = store(files);
    await Future.wait([
      for (var i = 0; i < 20; i++) s.put(StoredDownload(req('c$i'))),
      s.remove('c3'),
    ]);
    final loaded = await store(files).load();
    expect(loaded, hasLength(19));
    expect(loaded.containsKey('c3'), isFalse);
  });

  test('toString of a stored entry prints no field', () {
    expect('${StoredDownload(req('secret'))}', 'StoredDownload');
  });

  test('the real file store writes and reads on a disk', () async {
    final dir = await Directory.systemTemp.createTemp('fsp_dl_store');
    addTearDown(() => dir.delete(recursive: true));
    Future<String> bases(DownloadBase b) async => '${dir.path}/${b.name}';
    final path = '${dir.path}/support/fespalier_downloads.json';
    final s = FileDownloadStore(bases: bases);
    await s.put(StoredDownload(req('a')));
    expect(File(path).existsSync(), isTrue);
    expect(File('$path.tmp').existsSync(), isFalse);
    expect((await FileDownloadStore(bases: bases).load()).keys, ['a']);
    await s.clear();
    expect(File(path).existsSync(), isFalse);
  });

  test(
    'restart: the engine settles a stored download through the file store',
    () async {
      final files = FakeTransferFiles();
      final disk = FakeDownloadFiles();
      // First run: the app started three downloads and was closed.
      final first = Downloads(
        backend: FakeDownloadBackend(),
        store: store(files),
        files: disk,
      );
      await first.open();
      await first.start(req('done'));
      await first.start(req('gone'));
      await first.start(req('running'));
      await first.close();

      // While the app was closed, one finished and one was lost; one still runs.
      disk.put(const DownloadLocation(DownloadBase.cache, 'f/done.bin'), 10);
      final second = Downloads(
        backend: FakeDownloadBackend(replay: {'running': const Running(4, 10)}),
        store: store(files),
        files: disk,
      );
      await second.open();
      expect(
        second.statusOf('done'),
        const Complete(DownloadLocation(DownloadBase.cache, 'f/done.bin'), 10),
      );
      expect(second.statusOf('gone'), const Failed(DownloadFailure.killed));
      expect(second.statusOf('running'), const Running(4, 10));

      // Sign-out wipes the file store.
      await second.clearAccount();
      expect(await store(files).load(), isEmpty);
    },
  );
}
