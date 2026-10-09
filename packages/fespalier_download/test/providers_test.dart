import 'package:fespalier/fespalier.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadRequest req(String id) => DownloadRequest(
  id: id,
  url: Uri.parse('https://example.com/$id'),
  file: DownloadLocation(DownloadBase.support, 'f/$id.bin'),
);

Future<void> settle() => Future<void>.delayed(Duration.zero);

class _ThrowingStore extends MemoryDownloadStore {
  @override
  Future<Map<String, StoredDownload>> load() async => throw StateError('disk');
}

void main() {
  late FakeDownloadBackend backend;
  late MemoryDownloadStore store;

  ProviderContainer make({Map<String, DownloadStatus> replay = const {}}) {
    backend = FakeDownloadBackend(replay: replay);
    store = MemoryDownloadStore();
    final container = ProviderContainer(
      overrides: downloadTestOverrides(backend: backend, store: store),
    );
    addTearDown(container.dispose);
    return container;
  }

  test('without an override the engine provider names what to add', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(
      () => c.read(downloadsEngine),
      throwsA(
        predicate(
          (Object e) =>
              e.toString().contains('downloadsEngine') &&
              e.toString().contains('downloadTestOverrides') &&
              e.toString().contains('overrideWithValue'),
        ),
      ),
    );
  });

  test('status changes flow to downloads and downloadStatus', () async {
    final c = make();
    c.listen(downloads, (_, _) {});
    final seenA = <DownloadStatus>[];
    c.listen(downloadStatus('a'), (_, next) => seenA.add(next));
    final seenB = <DownloadStatus>[];
    c.listen(downloadStatus('b'), (_, next) => seenB.add(next));
    await settle();
    expect(c.read(downloadsEngine).isOpen, isTrue);
    expect(c.read(downloads), isEmpty);
    expect(c.read(downloadStatus('a')), const Absent());

    await c.read(downloadsEngine).start(req('a'));
    expect(c.read(downloadStatus('a')), const Queued());
    backend.emit('a', const Running(5, 10));
    expect(c.read(downloads)['a'], const Running(5, 10));
    expect(c.read(downloadStatus('a')), const Running(5, 10));
    backend.emit('a', const Running(7, 10));
    expect(c.read(downloadStatus('a')), const Running(7, 10));
    expect(seenA, [const Queued(), const Running(5, 10), const Running(7, 10)]);
    // b never changed, so its listener was never called.
    expect(seenB, isEmpty);

    await c.read(downloadsEngine).remove('a');
    expect(c.read(downloads), isEmpty);
    expect(c.read(downloadStatus('a')), const Absent());
  });

  test('what a restart left is in downloads once the engine opened', () async {
    final c = make(replay: {'x': const Running(1, 2)});
    await store.put(StoredDownload(req('x')));
    c.listen(downloads, (_, _) {});
    await settle();
    expect(c.read(downloads)['x'], const Running(1, 2));
  });

  test('disposing the container closes the engine and the backend', () async {
    final c = make();
    c.listen(downloads, (_, _) {});
    await settle();
    final engine = c.read(downloadsEngine);
    expect(engine.isOpen, isTrue);
    expect(backend.isOpen, isTrue);
    c.dispose();
    await settle();
    expect(engine.isOpen, isFalse);
    expect(backend.isOpen, isFalse);
  });

  test('an engine whose store throws on open leaves downloads empty', () async {
    final c = ProviderContainer(
      overrides: downloadTestOverrides(
        backend: FakeDownloadBackend(),
        store: _ThrowingStore(),
      ),
    );
    addTearDown(c.dispose);
    c.listen(downloads, (_, _) {});
    await settle();
    expect(c.read(downloads), isEmpty);
  });
}
