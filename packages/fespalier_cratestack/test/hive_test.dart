// HiveLocalStore: a durable store that never evicts. A plain test(): Hive does real file I/O.
import 'dart:io';

import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/hive.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(
    () =>
        dir = Directory.systemTemp.createTempSync('fespalier_cratestack_hive'),
  );
  tearDown(() => dir.deleteSync(recursive: true));

  Future<HiveLocalStore> open() =>
      HiveLocalStore.open(name: 'box', directory: dir.path);

  test('keys(prefix) lists the keys under a prefix, sorted', () async {
    final store = await open();
    await store.writeAll({'cs/a/1': 'x', 'cs/a/2': 'y', 'cs/b/1': 'z'});
    expect(store.keys('cs/a/'), ['cs/a/1', 'cs/a/2']);
    expect(store.keys('cs/'), hasLength(3));
    expect(store.keys('nope'), isEmpty);
    await store.close();
  });

  test('read, write and delete', () async {
    final store = await open();
    expect(store.read('k'), isNull);
    await store.write('k', 'v');
    expect(
      store.read('k'),
      'v',
      reason: 'a read after an awaited write is synchronous',
    );
    await store.delete('k');
    expect(store.read('k'), isNull);
    await store.close();
  });

  test('clear(prefix) deletes the keys under it and no others', () async {
    final store = await open();
    await store.writeAll({'cs/a/1': 'x', 'cs/a/2': 'y', 'cs/b/1': 'z'});
    await store.clear('cs/a/');
    expect(store.keys(''), ['cs/b/1']);
    await store.close();
  });

  test('what was written survives a reopen', () async {
    const name = 'durable';
    var store = await HiveLocalStore.open(name: name, directory: dir.path);
    await store.writeAll({'cs/a/intent/1': '{"id":"1"}', 'cs/node': 'abc'});
    await store.close();
    store = await HiveLocalStore.open(name: name, directory: dir.path);
    expect(store.read('cs/a/intent/1'), '{"id":"1"}');
    expect(store.read('cs/node'), 'abc');
    await store.close();
  });

  test('it never evicts: a lot of entries are all still there', () async {
    final store = await open();
    await store.writeAll({
      for (var i = 0; i < 3000; i++) 'cs/a/intent/$i': 'x' * 100,
    });
    expect(store.keys('cs/a/intent/'), hasLength(3000));
    await store.close();
  });

  test('off the web a directory is required, and the mistake says so', () {
    expect(HiveLocalStore.open(), throwsArgumentError);
  });

  test('a queued intent survives a restart and is sent after it', () async {
    const name = 'restart';
    var store = await HiveLocalStore.open(name: name, directory: dir.path);
    final transport = FakeCrateStackTransport()
      ..on('cancelOrder', (_) => 1)
      ..offline = true;
    var queue = IntentQueue(
      store: store,
      scope: () => 'u1',
      transport: () => transport,
      errors: () => const CrateStackErrors([]),
      bump: (_) {},
    );
    final out = await queue.submit<Object?>(
      const RpcCall('cancelOrder', {'id': 42}),
      decode: (o) => o,
    );
    expect(out, isA<Queued<Object?>>());
    final key = transport.calls.single.idempotencyKey;
    await store.close();

    // The process restarts: a new store over the same box, a new queue.
    store = await HiveLocalStore.open(name: name, directory: dir.path);
    transport.offline = false;
    queue = IntentQueue(
      store: store,
      scope: () => 'u1',
      transport: () => transport,
      errors: () => const CrateStackErrors([]),
      bump: (_) {},
    );
    final report = await queue.drain();
    expect(report.accepted, 1);
    expect(transport.calls.last.idempotencyKey, key);
    await store.close();
  });
}
