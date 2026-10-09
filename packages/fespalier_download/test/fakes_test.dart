import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:flutter_test/flutter_test.dart';

class Recorder implements DownloadEvents {
  final List<String> log = [];
  final List<int?> httpStatuses = [];

  @override
  void status(String id, DownloadStatus status, {int? httpStatus}) {
    log.add('$id $status');
    httpStatuses.add(httpStatus);
  }

  @override
  void tapped(String id, DownloadTapKind kind) =>
      log.add('$id tap ${kind.name}');
}

DownloadRequest request(String id) => DownloadRequest(
  id: id,
  url: Uri.parse('https://example.com/$id'),
  file: DownloadLocation(DownloadBase.support, 'f/$id'),
);

void main() {
  group('FakeDownloadBackend', () {
    test('records what the engine asks', () async {
      final backend = FakeDownloadBackend();
      expect(
        await backend.enqueue(request('a'), authorization: {'X': '1'}),
        isTrue,
      );
      expect(await backend.pause('a'), isTrue);
      expect(await backend.resume('a'), isTrue);
      await backend.cancel('a');
      await backend.cancelAll();
      await backend.configureNotifications(
        const DownloadNotifications(running: 'r'),
      );
      expect(backend.enqueued.single.id, 'a');
      expect(backend.authorizations, [
        {'X': '1'},
        <String, String>{},
      ]);
      expect(backend.paused, ['a']);
      expect(backend.resumed, ['a']);
      expect(backend.cancelled, ['a']);
      expect(backend.cancelAllCalls, 1);
      expect(backend.notifications?.running, 'r');
    });

    test('plays the platform through emit and tap once open', () async {
      final backend = FakeDownloadBackend();
      final events = Recorder();
      expect(() => backend.emit('a', const Queued()), throwsStateError);
      expect(() => backend.tap('a'), throwsStateError);
      await backend.open(events);
      expect(backend.isOpen, isTrue);
      backend.emit('a', const Running(1, 2), httpStatus: 206);
      backend.tap('a', DownloadTapKind.action);
      expect(events.log, ['a Running(1/2)', 'a tap action']);
      expect(events.httpStatuses, [206]);
      await backend.close();
      expect(backend.isOpen, isFalse);
      expect(() => backend.emit('a', const Queued()), throwsStateError);
    });

    test('replays what it was given to the listener at open', () async {
      final backend = FakeDownloadBackend(
        replay: {
          'a': const Running(1, 2),
          'b': const Failed(DownloadFailure.killed),
        },
      );
      final listener = Recorder();
      await backend.open(listener);
      expect(listener.log, ['a Running(1/2)', 'b Failed(killed)']);
    });

    test('can refuse, and capabilities bound pause', () async {
      final refusing = FakeDownloadBackend(accepts: false);
      expect(await refusing.enqueue(request('a')), isFalse);
      expect(await refusing.resume('a'), isFalse);
      final noPause = FakeDownloadBackend(
        capabilities: const DownloadCapabilities(),
      );
      expect(await noPause.pause('a'), isFalse);
      expect(await noPause.resume('a'), isFalse);
    });

    test('resolve gives a path that is not stored anywhere', () async {
      final backend = FakeDownloadBackend();
      expect(
        await backend.resolve(
          const DownloadLocation(DownloadBase.cache, 'a/b'),
        ),
        '/fake/cache/a/b',
      );
    });
  });

  group('MemoryDownloadStore', () {
    test('puts, replaces, removes, clears, and loads a copy', () async {
      final store = MemoryDownloadStore();
      await store.put(StoredDownload(request('a')));
      await store.put(StoredDownload(request('b')));
      await store.put(StoredDownload(request('a'), generation: 2));
      final loaded = await store.load();
      expect(loaded.keys, ['a', 'b']);
      expect(loaded['a']!.generation, 2);
      loaded.clear();
      expect(await store.load(), hasLength(2));
      await store.remove('a');
      expect((await store.load()).keys, ['b']);
      await store.clear();
      expect(await store.load(), isEmpty);
      expect(store.clearCalls, 1);
    });

    test('starts from an initial map without sharing it', () async {
      final initial = {'a': StoredDownload(request('a'))};
      final store = MemoryDownloadStore(initial);
      await store.remove('a');
      expect(initial, hasLength(1));
    });
  });

  group('FakeDownloadFiles', () {
    const file = DownloadLocation(DownloadBase.support, 'f/a');

    test('knows only the files put there, and deletes them', () async {
      final files = FakeDownloadFiles();
      expect(await files.exists(file), isFalse);
      expect(await files.length(file), isNull);
      files.put(file, 42);
      expect(await files.exists(file), isTrue);
      expect(await files.length(file), 42);
      await files.delete(file);
      expect(await files.exists(file), isFalse);
      expect(files.deleted, [file]);
      await files.delete(file);
      expect(files.deleted, hasLength(2));
    });

    test('starts from an initial map without sharing it', () async {
      final initial = {file: 1};
      final files = FakeDownloadFiles(initial);
      await files.delete(file);
      expect(initial, hasLength(1));
    });
  });
}
