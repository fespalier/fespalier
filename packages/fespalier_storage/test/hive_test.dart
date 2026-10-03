// HiveDataStorage over boxes opened with `bytes:`: in memory, no file, no plugin, and they complete under fake async.
import 'package:clock/clock.dart';
import 'package:fespalier/persist.dart';
import 'package:fespalier_storage/fespalier_storage.dart';
import 'package:fespalier_storage/src/bounded.dart';
import 'package:fespalier_storage/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'support.dart';

const options = StorageOptions();
final t0 = DateTime.utc(2026, 10, 3, 12);

Future<Box<String>> box() async {
  final opened = await memoryBox();
  addTearDown(opened.close);
  return opened;
}

/// The keys of [box] under the storage's prefix, without the prefix, sorted.
List<String> ours(Box<String> box) => [
  for (final key in box.keys)
    if (key is String && key.startsWith(storedKeyPrefix))
      key.substring(storedKeyPrefix.length),
]..sort();

void main() {
  testWidgets('a write is readable at once, synchronously', (tester) async {
    final opened = await box();
    final storage = HiveDataStorage(opened);
    expect(storage.maxSize, 4000000);
    expect(storage.maxEntries, 1000);
    expect(HiveDataStorage.defaultMaxSize, 4000000);
    expect(HiveDataStorage.defaultMaxEntries, 1000);
    final done = storage.write(
      'fespalier:teams/acme',
      '{"name":"ACME"}',
      const StorageOptions(destroyKey: '3'),
    );
    final saved = storage.read('fespalier:teams/acme');
    expect(saved, isA<PersistedData<String>>(), reason: 'not a Future');
    expect(saved!.data, '{"name":"ACME"}');
    expect(saved.destroyKey, '3');
    await done;
    expect(
      opened.get('${storedKeyPrefix}fespalier:teams/acme'),
      startsWith('fsc1\n'),
    );
  });

  testWidgets('a storage made again over the box is a restart', (tester) async {
    final opened = await box();
    final first = HiveDataStorage(opened);
    await first.write('fespalier:a', 'one', options);
    await first.write('fespalier:b', 'two', options);
    final second = HiveDataStorage(opened);
    expect(second.length, 2);
    expect(second.size, first.size);
    expect(second.read('fespalier:a')!.data, 'one');
  });

  testWidgets('expired entries are swept when the storage is made', (
    tester,
  ) async {
    final opened = await box();
    final first = HiveDataStorage(opened);
    await at(
      t0,
      () => first.write(
        'short',
        'v',
        const StorageOptions(
          cacheTime: StorageCacheTime(Duration(minutes: 10)),
        ),
      ),
    );
    await at(
      t0,
      () => first.write(
        'long',
        'v',
        const StorageOptions(cacheTime: StorageCacheTime(Duration(days: 2))),
      ),
    );
    final second = withClock(
      Clock.fixed(t0.add(const Duration(hours: 1))),
      () => HiveDataStorage(opened),
    );
    await second.sweepDone();
    expect(ours(opened), ['long']);
    expect(second.read('short'), isNull);
  });

  testWidgets('unreadable entries are dropped at once and counted (S3)', (
    tester,
  ) async {
    final opened = await box();
    await opened.put('${storedKeyPrefix}garbage', 'not an entry');
    late HiveDataStorage storage;
    final lines = await printed(() async {
      storage = HiveDataStorage(opened);
      await storage.sweepDone();
    });
    expect(lines, [
      'fespalier_storage: dropped 1 saved entries that could not be read',
    ]);
    expect(ours(opened), isEmpty);
    expect(storage.length, 0);
  });

  testWidgets('the box\'s other entries are never touched, even by clear()', (
    tester,
  ) async {
    final opened = await box();
    await opened.put('app.setting', 'dark');
    await opened.put('fespalier.dataCache', 'no slash');
    await opened.put(7, 'an int key');
    final storage = HiveDataStorage(opened, maxEntries: 1);
    await storage.write('a', '1', options);
    await storage.write('b', '2', options);
    expect(ours(opened), ['b']);
    await storage.clear();
    expect(ours(opened), isEmpty);
    expect(opened.get('app.setting'), 'dark');
    expect(opened.get('fespalier.dataCache'), 'no slash');
    expect(opened.get(7), 'an int key');
    expect(opened.length, 3);
  });

  testWidgets('eviction by maxEntries and by maxSize', (tester) async {
    final opened = await box();
    final storage = HiveDataStorage(opened, maxEntries: 2);
    await at(t0, () => storage.write('a', '1', options));
    await at(
      t0.add(const Duration(minutes: 1)),
      () => storage.write('b', '2', options),
    );
    await at(
      t0.add(const Duration(minutes: 2)),
      () => storage.write('c', '3', options),
    );
    expect(ours(opened), ['b', 'c']);
    final tiny = HiveDataStorage(opened, maxSize: 1);
    await tiny.sweepDone();
    expect(ours(opened), isEmpty);
  });

  testWidgets('a value over maxSize fails with DataEntryTooLarge', (
    tester,
  ) async {
    final opened = await box();
    final storage = HiveDataStorage(opened, maxSize: 120);
    await expectLater(
      storage.write('k', 'x' * 500, options),
      throwsA(isA<DataEntryTooLarge>()),
    );
    expect(ours(opened), isEmpty);
  });

  group('a key Hive cannot take', () {
    testWidgets('300 characters long round trips through the hashed key', (
      tester,
    ) async {
      final opened = await box();
      final storage = HiveDataStorage(opened);
      final key = 'fespalier:products/\$id[${'1' * 280}]';
      expect(key.length, greaterThan(255));
      await storage.write(key, 'long key data', options);
      final stored = opened.keys.single as String;
      expect(stored, startsWith('$storedKeyPrefix#'));
      expect(stored.length, 85, reason: 'the prefix, #, and 64 hex digits');
      expect(
        RegExp(
          r'^[0-9a-f]{64}$',
        ).hasMatch(stored.substring(storedKeyPrefix.length + 1)),
        isTrue,
      );
      expect(storage.read(key)!.data, 'long key data');
      // The entry says which key it is for.
      expect((opened.get(stored)!).split('\n')[4], '"$key"');
      // And it survives a restart.
      expect(HiveDataStorage(opened).read(key)!.data, 'long key data');
      await storage.delete(key);
      expect(opened.isEmpty, isTrue);
    });

    testWidgets('200 non-ASCII letters is more than 255 UTF-8 bytes', (
      tester,
    ) async {
      final opened = await box();
      final storage = HiveDataStorage(opened);
      final key = 'fespalier:${'é' * 200}';
      expect(
        key.length,
        lessThan(255),
        reason: 'short in characters, long in bytes',
      );
      await storage.write(key, 'accented', options);
      expect(opened.keys.single as String, startsWith('$storedKeyPrefix#'));
      expect(storage.read(key)!.data, 'accented');
    });

    testWidgets('a key of exactly 255 bytes stays plain, one more is hashed', (
      tester,
    ) async {
      final opened = await box();
      final storage = HiveDataStorage(opened);
      final room = 255 - storedKeyPrefix.length;
      final plain = 'k' * room;
      final hashed = 'k' * (room + 1);
      await storage.write(plain, '1', options);
      await storage.write(hashed, '2', options);
      final keys = opened.keys.cast<String>().toList()..sort();
      expect(keys.where((k) => k == '$storedKeyPrefix$plain'), hasLength(1));
      expect(
        keys.where((k) => k.startsWith('$storedKeyPrefix#')),
        hasLength(1),
      );
      expect(storage.read(plain)!.data, '1');
      expect(storage.read(hashed)!.data, '2');
    });

    testWidgets(
      'an entry that is for another key (a collision) is a miss, not corruption',
      (tester) async {
        final opened = await box();
        final storage = HiveDataStorage(opened);
        final key = 'fespalier:${'x' * 300}';
        await storage.write(key, 'mine', options);
        final stored = opened.keys.single as String;
        final lines = opened.get(stored)!.split('\n');
        lines[4] = '"fespalier:somebody-else"';
        await opened.put(stored, lines.join('\n'));
        final restarted = HiveDataStorage(opened);
        expect(restarted.read(key), isNull);
        expect(
          opened.containsKey(stored),
          isTrue,
          reason: 'it is somebody else\'s entry: not deleted',
        );
      },
    );
  });

  testWidgets('close() closes the box', (tester) async {
    final opened = await memoryBox();
    final storage = HiveDataStorage(opened);
    expect(opened.isOpen, isTrue);
    await storage.close();
    expect(opened.isOpen, isFalse);
  });

  testWidgets(
    'each memoryBox() is a new, empty box, and a name opens it again empty',
    (tester) async {
      final first = await memoryBox();
      await first.put('k', 'v');
      final second = await memoryBox();
      expect(second.name, isNot(first.name));
      expect(second.isEmpty, isTrue);
      final named = await memoryBox('fespalier_storage_named');
      await named.put('k', 'v');
      final again = await memoryBox('fespalier_storage_named');
      expect(again.isEmpty, isTrue);
      expect(
        named.isOpen,
        isFalse,
        reason: 'an open box of that name is closed first',
      );
      addTearDown(first.close);
      addTearDown(second.close);
      addTearDown(again.close);
    },
  );

  testWidgets('open() with no plugin is null, and says why (S5)', (
    tester,
  ) async {
    HiveDataStorage? storage;
    // A platform channel call needs the real event loop: a widget test's fake one never answers it.
    final lines = await printed(
      () => tester.runAsync(
        () async => storage = await HiveDataStorage.open(
          name: 'fespalier_storage_no_plugin',
        ),
      ),
    );
    expect(storage, isNull);
    expect(lines, [
      'fespalier_storage: could not open the Hive box fespalier_storage_no_plugin, so nothing is saved: '
          'MissingPluginException(No implementation found for method getApplicationCacheDirectory on channel '
          'plugins.flutter.io/path_provider)',
    ]);
  });

  testWidgets('a budget of 0 is the app\'s mistake: open() throws (S7)', (
    tester,
  ) async {
    await expectLater(HiveDataStorage.open(maxEntries: 0), throwsArgumentError);
    final opened = await box();
    expect(() => HiveDataStorage(opened, maxSize: 0), throwsArgumentError);
  });
}
