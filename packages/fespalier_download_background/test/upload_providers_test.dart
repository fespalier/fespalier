import 'package:fespalier/fespalier.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download_background/fespalier_download_background.dart';
import 'package:fespalier_download_background/testing.dart';
import 'package:flutter_test/flutter_test.dart';

UploadRequest req(String id) => UploadRequest(
  id: id,
  url: Uri.parse('https://api.example.com/$id'),
  file: DownloadLocation(DownloadBase.support, 'f/$id.jpg'),
);

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeUploadBackend backend;

  ProviderContainer make({Map<String, DownloadStatus> replay = const {}}) {
    backend = FakeUploadBackend(replay: replay);
    final store = MemoryUploadStore({
      for (final id in replay.keys) id: StoredUpload(req(id)),
    });
    final container = ProviderContainer(
      overrides: uploadTestOverrides(backend: backend, store: store),
    );
    addTearDown(container.dispose);
    return container;
  }

  test('without an override the engine provider names what to add', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(
      () => c.read(uploadsEngine),
      throwsA(
        predicate(
          (Object e) =>
              e.toString().contains('uploadsEngine') &&
              e.toString().contains('uploadTestOverrides'),
        ),
      ),
    );
  });

  test('status changes flow to uploads and uploadStatus', () async {
    final c = make();
    c.listen(uploads, (_, _) {});
    final seenA = <DownloadStatus>[];
    c.listen(uploadStatus('a'), (_, next) => seenA.add(next));
    await settle();
    expect(c.read(uploadsEngine).isOpen, isTrue);
    expect(c.read(uploadStatus('a')), const Absent());
    await c.read(uploadsEngine).start(req('a'));
    await settle();
    backend.emit('a', const Running(1, 4));
    await settle();
    expect(seenA, [const Queued(), const Running(1, 4)]);
    expect(c.read(uploads).keys, ['a']);
  });

  test('what the platform kept shows after open', () async {
    final c = make(replay: {'a': const Failed(DownloadFailure.network)});
    c.listen(uploads, (_, _) {});
    await settle();
    expect(c.read(uploadStatus('a')), const Failed(DownloadFailure.network));
  });

  test(
    'disposing the container clears the observer and closes the backend',
    () async {
      final c = make();
      c.listen(uploads, (_, _) {});
      await settle();
      c.dispose();
      await settle();
      expect(backend.isOpen, isFalse);
    },
  );
}
