// The file pack's telemetry contract: one operation per download, kind `file`, constants only, and
// nothing of the pack (its key, URL, paths, hash or headers) in what a sink hears.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pack_server.dart';

const secretKey = 'secret-shop-douala';
const secretPath = '/data/secret-dir/douala.pmtiles';

void main() {
  late RecordingTelemetry rec;
  late PackServer server;
  late FakePackFiles files;
  late ProviderContainer container;
  final body = sampleBody(450);

  FilePackRequest request({String? sha256}) => FilePackRequest(
    key: secretKey,
    url: Uri.parse('https://secret-host.example.com/token-abc/douala.pmtiles'),
    destination: secretPath,
    sha256: sha256,
    headers: const {'Authorization': 'Bearer secret-token'},
  );

  setUp(() {
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    addTearDown(() => FespalierTelemetry.install(null));
    server = PackServer(body);
    files = FakePackFiles();
    container = ProviderContainer(
      overrides: [
        packHttpClient.overrideWithValue(server.client),
        packFileStore.overrideWithValue(files),
      ],
    );
    addTearDown(container.dispose);
  });

  test('the new name is the contract', () {
    expect(MapsTelemetry.kindFile, 'file');
    expect(MapsTelemetry.download, 'fespalier.maps.download');
  });

  test('a download is one operation of kind file', () async {
    await container.read(filePacks.notifier).start(request());
    expect(rec.log, [
      '#1 start custom fespalier.maps.download fespalier.maps.kind=file',
      '#1 end custom ok async fespalier.maps.result=complete',
    ]);
  });

  test('a failure ends it with outcome error', () async {
    await container.read(filePacks.notifier).start(request(sha256: '0' * 64));
    expect(
      rec.log.last,
      '#1 end custom error async fespalier.maps.result=failed',
    );
  });

  test('a pause and its resume are one operation', () async {
    final gate = Completer<void>();
    server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
    final packs = container.read(filePacks.notifier);
    final done = packs.start(request());
    await pumpEventQueue();
    final paused = packs.pause(secretKey);
    gate.complete();
    await paused;
    await done;
    expect(rec.log.where((l) => l.contains(' end ')), isEmpty);
    server.beforeChunk = null;
    await packs.resume(secretKey);
    expect(rec.log.where((l) => l.contains(' start ')), hasLength(1));
    expect(
      rec.log.last,
      '#1 end custom ok async fespalier.maps.result=complete',
    );
  });

  test('a removal and the end of the provider end it as cancelled', () async {
    final gate = Completer<void>();
    server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
    final packs = container.read(filePacks.notifier);
    final done = packs.start(request());
    await pumpEventQueue();
    final removed = packs.remove(secretKey);
    gate.complete();
    await removed;
    await done;
    expect(
      rec.log.last,
      '#1 end custom superseded async fespalier.maps.result=cancelled',
    );
  });

  test('nothing of the pack reaches a sink', () async {
    server.breakAfter = 200;
    final packs = container.read(filePacks.notifier);
    await packs.start(request());
    await packs.resume(secretKey);
    final heard = rec.log.join('\n');
    expect(heard, isNotEmpty);
    for (final secret in [
      secretKey,
      'secret-host',
      'token-abc',
      'secret-dir',
      'douala',
      'secret-token',
      'Authorization',
    ]) {
      expect(heard, isNot(contains(secret)));
    }
  });

  test('with no sink, nothing is started', () async {
    FespalierTelemetry.install(null);
    await container.read(filePacks.notifier).start(request());
    expect(rec.log, isEmpty);
  });
}
