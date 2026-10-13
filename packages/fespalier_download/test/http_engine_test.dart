// The engine over the foreground backend: what an app gets from Downloads(HttpDownloadBackend),
// including the telemetry a sink hears, which carries constants only.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'file_server.dart';
import 'rig.dart' show defaultBases, loc;

const secretId = 'secret-id-douala';
const secretPath = 'secret-dir/douala.pmtiles';
const onDisk = '/packs/$secretPath';

DownloadRequest secret({String? sha256, int? bytes}) => DownloadRequest(
  id: secretId,
  url: Uri.parse('https://secret-host.example.com/token-abc/douala.pmtiles'),
  file: const DownloadLocation(DownloadBase.support, secretPath),
  headers: const {'Authorization': 'Bearer secret-token'},
  sha256: sha256,
  bytes: bytes,
  displayName: 'Secret name',
);

void main() {
  final body = sampleBody(450);
  late FileServer server;
  late FakeTransferFiles files;
  late RecordingTelemetry rec;
  late MemoryDownloadStore store;

  Downloads make() => Downloads(
    backend: HttpDownloadBackend(
      client: server.client,
      bases: defaultBases,
      files: files,
    ),
    store: store,
    files: TransferDownloadFiles(bases: defaultBases, files: files),
  );

  Future<void> until(
    Downloads d,
    String id,
    bool Function(DownloadStatus) test,
  ) async {
    final done = Completer<void>();
    d.observe((i, s) {
      if (i == id && test(s) && !done.isCompleted) done.complete();
    });
    if (test(d.statusOf(id))) return;
    await done.future;
  }

  bool ended(DownloadStatus s) => s is Complete || s is Failed || s is Paused;

  setUp(() {
    server = FileServer(body);
    files = FakeTransferFiles();
    store = MemoryDownloadStore();
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    addTearDown(() => FespalierTelemetry.install(null));
  });

  test(
    'a download is one transfer span, and pathOf resolves the file',
    () async {
      final d = make();
      await d.open();
      await d.start(secret(sha256: sha256Of(body)));
      await until(d, secretId, ended);
      expect(
        d.statusOf(secretId),
        const Complete(DownloadLocation(DownloadBase.support, secretPath), 450),
      );
      expect(files.bytesOf(onDisk), body);
      expect(await d.pathOf(secretId), onDisk);
      expect(rec.log.length, 2);
      expect(
        rec.log.first,
        startsWith('#1 start custom fespalier.download.transfer'),
      );
      expect(rec.log.first, contains('fespalier.download.background=false'));
      expect(
        rec.log.last,
        '#1 end custom ok async fespalier.download.result=complete',
      );
    },
  );

  test('nothing of the request reaches a sink', () async {
    server.breakAfter = 200;
    final d = make();
    await d.open();
    await d.start(secret());
    await until(d, secretId, ended);
    await d.retry(secretId);
    await until(d, secretId, (s) => s is Complete);
    final heard = rec.log.join('\n');
    expect(heard, isNotEmpty);
    for (final s in [
      secretId,
      'secret-host',
      'token-abc',
      'secret-dir',
      'douala',
      'secret-token',
      'Authorization',
      'Secret name',
    ]) {
      expect(heard, isNot(contains(s)));
    }
  });

  test('a failure ends the span with outcome error', () async {
    final d = make();
    await d.open();
    await d.start(secret(sha256: '0' * 64));
    await until(d, secretId, ended);
    expect(rec.log.last, startsWith('#1 end custom error async'));
    expect(rec.log.last, contains('fespalier.download.result=failed'));
    expect(rec.log.last, contains('fespalier.download.failure=hashMismatch'));
  });

  test('a retry after a network failure goes on from the bytes kept', () async {
    server.breakAfter = 200;
    final d = make();
    await d.open();
    await d.start(secret(bytes: 450));
    await until(d, secretId, ended);
    expect(d.statusOf(secretId), const Failed(DownloadFailure.network));
    expect(files.bytesOf('$onDisk.part'), body.sublist(0, 200));
    await d.retry(secretId);
    await until(d, secretId, (s) => s is Complete);
    expect(server.requests.last['range'], 'bytes=200-');
    expect(files.bytesOf(onDisk), body);
  });

  test('pause and resume keep one span, and Range goes on', () async {
    final gate = Completer<void>();
    server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
    final d = make();
    await d.open();
    await d.start(secret());
    await pumpEventQueue();
    final paused = d.pause(secretId);
    gate.complete();
    expect(await paused, isTrue);
    await until(d, secretId, (s) => s is Paused);
    server.beforeChunk = null;
    expect(await d.resume(secretId), isTrue);
    await until(d, secretId, (s) => s is Complete);
    expect(server.requests.last['range'], 'bytes=100-');
    expect(rec.log.where((l) => l.contains(' start ')), hasLength(1));
  });

  test(
    'after a restart the engine finds the download ended, and retry continues it',
    () async {
      final gate = Completer<void>();
      server.beforeChunk = (i) => i == 2 ? gate.future : Future<void>.value();
      final first = make();
      await first.open();
      await first.start(secret(bytes: 450));
      await pumpEventQueue();
      await first.close();
      gate.complete();
      await pumpEventQueue();
      final kept = files.bytesOf('$onDisk.part')!.length;
      server.beforeChunk = null;

      final second = make();
      await second.open();
      expect(second.statusOf(secretId), const Failed(DownloadFailure.killed));
      await second.retry(secretId);
      await until(second, secretId, (s) => s is Complete);
      expect(server.requests.last['range'], 'bytes=$kept-');
      expect(files.bytesOf(onDisk), body);
    },
  );

  test('remove deletes the file, the partial file and the validator', () async {
    final d = make();
    await d.open();
    await d.start(secret());
    await until(d, secretId, ended);
    await d.remove(secretId);
    expect(files.paths, isEmpty);
    expect(d.statusOf(secretId), const Absent());
  });

  test('sign-out cancels a running download and deletes its files', () async {
    server.beforeChunk = (i) =>
        i == 1 ? Completer<void>().future : Future<void>.value();
    final d = make();
    await d.open();
    await d.start(secret());
    await pumpEventQueue();
    expect(files.bytesOf('$onDisk.part'), isNotNull);
    await d.clearAccount();
    expect(files.paths, isEmpty);
    expect(store.entries, isEmpty);
  });

  test('a user-initiated request is refused: no notifications here', () async {
    final d = make();
    await d.open();
    await d.start(
      DownloadRequest(
        id: 'u',
        url: Uri.parse('https://example.com/u'),
        file: loc,
        priority: DownloadPriority.userInitiated,
      ),
    );
    expect(
      d.statusOf('u'),
      const Failed(DownloadFailure.notificationsRequired),
    );
    expect(server.requests, isEmpty);
  });

  test(
    'with no files (the web) a start ends unsupported, before a request',
    () async {
      files.unsupported = true;
      final d = make();
      await d.open();
      await d.start(secret());
      await until(d, secretId, ended);
      expect(d.statusOf(secretId), const Failed(DownloadFailure.unsupported));
      expect(server.requests, isEmpty);
    },
  );
}
