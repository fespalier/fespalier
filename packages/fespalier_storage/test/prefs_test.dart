// PrefsDataStorage over shared_preferences' in-memory fake: no file, no plugin.
import 'package:clock/clock.dart';
import 'package:fespalier/persist.dart';
import 'package:fespalier_storage/fespalier_storage.dart';
import 'package:fespalier_storage/src/bounded.dart';
import 'package:fespalier_storage/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support.dart';

const options = StorageOptions();
final t0 = DateTime.utc(2026, 10, 3, 12);

/// What the platform holds, read afresh (a new SharedPreferencesWithCache reloads it).
Future<Set<String>> platformKeys() async =>
    (await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    )).keys;

void main() {
  setUp(fakePrefsStore);

  test('open() on an empty store', () async {
    final storage = await PrefsDataStorage.open();
    expect(storage, isNotNull);
    expect(storage!.length, 0);
    expect(storage.size, 0);
    expect(storage.maxSize, PrefsDataStorage.defaultMaxSize);
    expect(storage.maxEntries, PrefsDataStorage.defaultMaxEntries);
    expect(PrefsDataStorage.defaultMaxSize, 1000000);
    expect(PrefsDataStorage.defaultMaxEntries, 200);
  });

  test('a write is readable at once, synchronously', () async {
    final storage = (await PrefsDataStorage.open())!;
    final done = storage.write(
      'fespalier:teams/acme',
      '{"name":"ACME"}',
      options,
    );
    final saved = storage.read('fespalier:teams/acme');
    expect(
      saved,
      isA<PersistedData<String>>(),
      reason: 'not a Future: the first frame can use it',
    );
    expect(saved!.data, '{"name":"ACME"}');
    await done;
    expect(await platformKeys(), {'${storedKeyPrefix}fespalier:teams/acme'});
  });

  test('a second open() is a restart: what was saved is there', () async {
    final first = (await PrefsDataStorage.open())!;
    await first.write(
      'fespalier:teams/acme',
      'one',
      const StorageOptions(destroyKey: '2'),
    );
    await first.write('fespalier:teams/zed', 'two', options);
    final second = (await PrefsDataStorage.open())!;
    expect(second.length, 2);
    final saved = second.read('fespalier:teams/acme')!;
    expect(saved.data, 'one');
    expect(saved.destroyKey, '2');
    expect(second.read('fespalier:teams/zed')!.data, 'two');
    expect(second.size, first.size);
  });

  test('open() sweeps what expired, and waits for the deletes', () async {
    final first = (await PrefsDataStorage.open())!;
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
    final second = await withClock(
      Clock.fixed(t0.add(const Duration(hours: 1))),
      PrefsDataStorage.open,
    );
    expect(second!.length, 1);
    expect(second.read('short'), isNull);
    expect(second.read('long'), isNotNull);
    // open() waited: the platform no longer holds it.
    expect(await platformKeys(), {'${storedKeyPrefix}long'});
  });

  test('open() drops what it cannot read, and says so (S3)', () async {
    fakePrefsStore({
      '${storedKeyPrefix}garbage': 'not an entry',
      '${storedKeyPrefix}typed': 42,
    });
    late PrefsDataStorage storage;
    final lines = await printed(
      () async => storage = (await PrefsDataStorage.open())!,
    );
    expect(lines, [
      'fespalier_storage: dropped 2 saved entries that could not be read',
    ]);
    expect(storage.length, 0);
    expect(await platformKeys(), isEmpty);
  });

  test('the app\'s own keys are never touched, even by clear()', () async {
    fakePrefsStore({
      'app.setting': 'dark',
      'app.count': 3,
      'app.flags': <String>['a'],
    });
    final storage = (await PrefsDataStorage.open(maxEntries: 1))!;
    await storage.write('a', '1', options);
    await storage.write('b', '2', options); // evicts a
    expect(await platformKeys(), {
      'app.setting',
      'app.count',
      'app.flags',
      '${storedKeyPrefix}b',
    });
    await storage.clear();
    expect(await platformKeys(), {'app.setting', 'app.count', 'app.flags'});
    final prefs = await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    );
    expect(prefs.getString('app.setting'), 'dark');
    expect(prefs.getInt('app.count'), 3);
  });

  test('eviction and the size budget apply to the real store', () async {
    final storage = (await PrefsDataStorage.open(maxEntries: 2))!;
    await at(t0, () => storage.write('a', '1', options));
    await at(
      t0.add(const Duration(minutes: 1)),
      () => storage.write('b', '2', options),
    );
    await at(
      t0.add(const Duration(minutes: 2)),
      () => storage.write('c', '3', options),
    );
    expect(await platformKeys(), {
      '${storedKeyPrefix}b',
      '${storedKeyPrefix}c',
    });
    final tiny = (await PrefsDataStorage.open(maxSize: 1))!;
    expect(
      tiny.length,
      0,
      reason: 'the budget is below one entry: all evicted at open',
    );
    expect(await platformKeys(), isEmpty);
  });

  test(
    'a value over maxSize fails with DataEntryTooLarge and leaves nothing',
    () async {
      final storage = (await PrefsDataStorage.open(maxSize: 120))!;
      await expectLater(
        storage.write('k', 'x' * 500, options),
        throwsA(isA<DataEntryTooLarge>()),
      );
      expect(await platformKeys(), isEmpty);
    },
  );

  test(
    'an instance with an allowList is refused (S6), before anything is swept',
    () async {
      final prefs = await SharedPreferencesWithCache.create(
        cacheOptions: const SharedPreferencesWithCacheOptions(
          allowList: {'app.setting'},
        ),
      );
      expect(
        () => PrefsDataStorage(prefs),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'toString',
            'Invalid argument(s): PrefsDataStorage needs a SharedPreferencesWithCache without an allowList: '
                'the keys of a dataCache are not known in advance. Use PrefsDataStorage.open(), or create it with '
                'const SharedPreferencesWithCacheOptions().',
          ),
        ),
      );
      final empty = await SharedPreferencesWithCache.create(
        cacheOptions: const SharedPreferencesWithCacheOptions(
          allowList: <String>{},
        ),
      );
      expect(() => PrefsDataStorage(empty), throwsArgumentError);
    },
  );

  test('an instance without one is taken as it is', () async {
    final prefs = await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    );
    final storage = PrefsDataStorage(prefs, maxEntries: 3);
    expect(storage.maxEntries, 3);
    await storage.write('k', 'v', options);
    expect(prefs.getString('${storedKeyPrefix}k'), isNotNull);
  });

  test('open() with no platform is null, and says why (S4)', () async {
    SharedPreferencesAsyncPlatform.instance = null;
    PrefsDataStorage? storage;
    final lines = await printed(
      () async => storage = await PrefsDataStorage.open(),
    );
    expect(storage, isNull);
    expect(lines, [
      'fespalier_storage: could not open shared preferences, so nothing is saved: '
          'Bad state: The SharedPreferencesAsyncPlatform instance must be set.',
    ]);
  });

  test(
    'a budget of 0 is the app\'s mistake: open() throws (S7), it does not return null',
    () async {
      await expectLater(
        PrefsDataStorage.open(maxSize: 0),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'toString',
            'Invalid argument (maxSize): must be more than 0: 0',
          ),
        ),
      );
      await expectLater(
        PrefsDataStorage.open(maxEntries: -1),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'toString',
            'Invalid argument (maxEntries): must be more than 0: -1',
          ),
        ),
      );
    },
  );
}
