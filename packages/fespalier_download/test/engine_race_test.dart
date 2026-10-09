// A remove or a cancel that is waiting for the backend never touches a download of the same id
// that was started in the meantime: the new one keeps its registry entry and its files.
import 'dart:async';

import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _loc = DownloadLocation(DownloadBase.support, 'f/a.bin');

DownloadRequest _req() => DownloadRequest(
  id: 'a',
  url: Uri.parse('https://example.com/a'),
  file: _loc,
);

// A backend whose cancel waits for the test.
class _SlowCancel extends FakeDownloadBackend {
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> cancel(String id) async {
    await super.cancel(id);
    await gate.future;
  }
}

void main() {
  for (final verb in ['remove', 'cancel']) {
    test(
      '$verb then start of the same id keeps the new entry and file',
      () async {
        final backend = _SlowCancel();
        final store = MemoryDownloadStore();
        final files = FakeDownloadFiles();
        final engine = Downloads(backend: backend, store: store, files: files);
        await engine.open();
        await engine.start(_req());
        final pending = verb == 'remove'
            ? engine.remove('a')
            : engine.cancel('a');
        await pumpEventQueue();
        expect(backend.cancelled, ['a']);

        // The id is started again while the backend is still stopping the old one.
        await engine.start(_req());
        expect(store.entries.keys, ['a']);
        files.put(_loc, 10);

        backend.gate.complete();
        await pending;
        expect(store.entries.keys, [
          'a',
        ], reason: 'the new registry entry stays');
        expect(files.deleted, isEmpty, reason: 'the new file stays');
        expect(files.sizes[_loc], 10);
        expect(engine.statusOf('a'), const Queued());
      },
    );
  }
}
