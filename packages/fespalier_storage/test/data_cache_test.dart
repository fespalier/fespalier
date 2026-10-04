// Both storages end to end through fespalier's own `cachedData` and `dataCacheStorage`: what an app gets. A restart is
// a second storage over the same store; every test ends with its containers disposed and no timer pending.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/persist.dart' show Storage;
import 'package:fespalier_storage/fespalier_storage.dart';
import 'package:fespalier_storage/src/bounded.dart';
import 'package:fespalier_storage/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One store, and a way to open a storage over it again (a restart) and to plant a bad entry in it.
abstract class Backend {
  String get name;

  /// A storage over the store, as a start of the app makes it.
  Future<BoundedDataStorage> open({int? maxSize});

  /// Puts [value] under [storedKey] in the store, behind the storage's back.
  Future<void> plant(String storedKey, String value);
}

final class PrefsBackend extends Backend {
  SharedPreferencesWithCache? _prefs;

  @override
  String get name => 'PrefsDataStorage';

  @override
  Future<BoundedDataStorage> open({int? maxSize}) async {
    final prefs = _prefs = await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    );
    return PrefsDataStorage(
      prefs,
      maxSize: maxSize ?? PrefsDataStorage.defaultMaxSize,
    );
  }

  @override
  Future<void> plant(String storedKey, String value) =>
      _prefs!.setString(storedKey, value);
}

final class HiveBackend extends Backend {
  Box<String>? _box;

  @override
  String get name => 'HiveDataStorage';

  @override
  Future<BoundedDataStorage> open({int? maxSize}) async {
    final box = _box ??= await memoryBox();
    addTearDown(box.close);
    return HiveDataStorage(
      box,
      maxSize: maxSize ?? HiveDataStorage.defaultMaxSize,
    );
  }

  @override
  Future<void> plant(String storedKey, String value) =>
      _box!.put(storedKey, value);
}

var fetches = 0;
var failing = false;

/// The route's data: a team's name, saved for the next start.
AsyncNotifierProvider<CachedData<String>, String> team({
  String? version,
  Duration maxAge = const Duration(days: 2),
  String Function(String saved)? decode,
}) => cachedData<String>(
  (ref) async {
    fetches++;
    if (failing) throw StateError('offline');
    return 'Team ACME';
  },
  cache: DataCache<String>(
    encode: (value) => value,
    decode: decode ?? (saved) => saved,
    version: version,
    maxAge: maxAge,
  ),
  name: 'teams/acme',
);

/// The saved key `cachedData` uses for [team]: the storage's key, then the prefix.
const key = 'fespalier:teams/acme';

/// One start of the app: a container whose `dataCacheStorage` is [storage], watching [provider].
({ProviderContainer container, ProviderSubscription<AsyncValue<String>> sub})
start(
  Storage<String, String> storage,
  AsyncNotifierProvider<CachedData<String>, String> provider,
) {
  final container = ProviderContainer(
    overrides: [dataCacheStorage.overrideWithValue(storage)],
    retry: (count, error) => null,
  );
  addTearDown(container.dispose);
  final sub = container.listen(provider, (_, _) {});
  addTearDown(sub.close);
  return (container: container, sub: sub);
}

/// Ends a start: disposes it and lets the container's disposal timer fire, so nothing is pending.
Future<void> stop(WidgetTester tester, ProviderContainer container) async {
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
}

/// Runs [body] with `debugPrint` captured.
Future<List<String>> printed(FutureOr<void> Function() body) async {
  final lines = <String>[];
  final original = debugPrint;
  debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
  try {
    await body();
  } finally {
    debugPrint = original;
  }
  return lines;
}

void main() {
  setUp(() {
    fetches = 0;
    failing = false;
    fakePrefsStore();
  });

  for (final make in <Backend Function()>[PrefsBackend.new, HiveBackend.new]) {
    final name = make().name;
    group(name, () {
      late Backend backend;
      setUp(() => backend = make());

      /// A first start that loads and saves the team, then goes away: what the previous session did.
      Future<void> firstSession(WidgetTester tester, {String? version}) async {
        final storage = await backend.open();
        final first = start(storage, team(version: version));
        await tester.pump();
        expect(first.sub.read().value, 'Team ACME');
        await tester.pump();
        await stop(tester, first.container);
        expect(
          storage.read(key),
          isNotNull,
          reason: 'the fresh value was saved',
        );
      }

      testWidgets(
        'the first read after a restart is the saved value, synchronously',
        (tester) async {
          await firstSession(tester);
          expect(fetches, 1);
          final restarted = await backend.open();
          final second = start(restarted, team());
          // Nothing has been pumped: this is the first frame.
          final first = second.sub.read();
          expect(first.isLoading, isTrue);
          expect(first.isFromCache, isTrue);
          expect(first.value, 'Team ACME');
          await tester.pump();
          final fresh = second.sub.read();
          expect(fetches, 2, reason: 'a cold start always loads');
          expect(fresh.isFromCache, isFalse);
          expect(fresh.value, 'Team ACME');
          await stop(tester, second.container);
        },
      );

      testWidgets(
        'with no saved value the first read is loading with nothing',
        (tester) async {
          final storage = await backend.open();
          final started = start(storage, team());
          final first = started.sub.read();
          expect(first.isLoading, isTrue);
          expect(first.hasValue, isFalse);
          await tester.pump();
          await stop(tester, started.container);
        },
      );

      testWidgets(
        'a failing fetch keeps the saved entry, and the next restart still shows it',
        (tester) async {
          await firstSession(tester);
          failing = true;
          final storage = await backend.open();
          final offline = start(storage, team());
          expect(offline.sub.read().isFromCache, isTrue);
          await tester.pump();
          final after = offline.sub.read();
          expect(after.hasError, isTrue, reason: 'the fetch failed');
          expect(
            after.value,
            'Team ACME',
            reason: 'the saved value is still on screen',
          );
          expect(
            storage.read(key),
            isNotNull,
            reason: 'fespalier does not delete it on an error',
          );
          await stop(tester, offline.container);

          final again = start(await backend.open(), team());
          expect(again.sub.read().value, 'Team ACME');
          expect(again.sub.read().isFromCache, isTrue);
          await tester.pump();
          await stop(tester, again.container);
        },
      );

      testWidgets(
        'a changed DataCache version is not shown, and the saved value is deleted',
        (tester) async {
          await firstSession(tester, version: '1');
          final storage = await backend.open();
          final restarted = start(storage, team(version: '2'));
          final first = restarted.sub.read();
          expect(first.isFromCache, isFalse);
          expect(
            first.hasValue,
            isFalse,
            reason: 'a value of another version is dropped, not decoded',
          );
          expect(storage.read(key), isNull);
          await tester.pump();
          expect(
            storage.read(key)!.destroyKey,
            '2',
            reason: 'the fresh value is saved with the new version',
          );
          await stop(tester, restarted.container);
        },
      );

      testWidgets('a value older than maxAge is not shown, and is deleted', (
        tester,
      ) async {
        final storage = await backend.open();
        final first = start(storage, team(maxAge: const Duration(minutes: 5)));
        await tester.pump();
        await tester.pump();
        await stop(tester, first.container);
        expect(storage.read(key), isNotNull);

        await tester.pump(const Duration(minutes: 10)); // the fake clock
        final restarted = start(
          await backend.open(),
          team(maxAge: const Duration(minutes: 5)),
        );
        final read = restarted.sub.read();
        expect(read.isFromCache, isFalse);
        expect(read.hasValue, isFalse);
        await tester.pump();
        await stop(tester, restarted.container);
      });

      testWidgets('a value younger than maxAge still shows', (tester) async {
        final storage = await backend.open();
        final first = start(storage, team(maxAge: const Duration(minutes: 5)));
        await tester.pump();
        await tester.pump();
        await stop(tester, first.container);
        await tester.pump(const Duration(minutes: 4));
        final restarted = start(
          await backend.open(),
          team(maxAge: const Duration(minutes: 5)),
        );
        expect(restarted.sub.read().isFromCache, isTrue);
        await tester.pump();
        await stop(tester, restarted.container);
      });

      testWidgets(
        'a saved value the app cannot decode is dropped with fespalier\'s line, and deleted',
        (tester) async {
          await firstSession(tester);
          final storage = await backend.open();
          late ({
            ProviderContainer container,
            ProviderSubscription<AsyncValue<String>> sub,
          })
          started;
          final lines = await printed(() async {
            started = start(
              storage,
              team(
                decode: (saved) =>
                    throw const FormatException('the shape changed'),
              ),
            );
            await tester.pump();
          });
          expect(lines, [
            'fespalier: dataCache of teams/acme could not read a saved value, dropped it: '
                'FormatException: the shape changed',
          ]);
          expect(started.sub.read().isFromCache, isFalse);
          await stop(tester, started.container);
        },
      );

      testWidgets(
        'an entry the storage cannot read is dropped with fespalier\'s line carrying S2, and deleted',
        (tester) async {
          final storage = await backend.open();
          await backend.plant(
            '$storedKeyPrefix$key',
            'not an entry this storage wrote',
          );
          late ({
            ProviderContainer container,
            ProviderSubscription<AsyncValue<String>> sub,
          })
          started;
          final lines = await printed(() async {
            started = start(storage, team());
            await tester.pump();
          });
          expect(lines, [
            'fespalier: dataCache of teams/acme could not read a saved value, dropped it: '
                'FormatException: fespalier_storage: a saved entry is not one this storage wrote (format fsc1)',
          ]);
          expect(
            started.sub.read().value,
            'Team ACME',
            reason: 'the route went on and loaded',
          );
          await tester.pump();
          expect(
            storage.read(key)!.data,
            'Team ACME',
            reason: 'the fresh value replaced the bad entry',
          );
          await stop(tester, started.container);
        },
      );

      testWidgets(
        'a value over maxSize is not saved, with fespalier\'s line carrying S1, and the route works',
        (tester) async {
          final storage = await backend.open(maxSize: 60);
          late ({
            ProviderContainer container,
            ProviderSubscription<AsyncValue<String>> sub,
          })
          started;
          final lines = await printed(() async {
            started = start(storage, team());
            await tester.pump();
            await tester.pump();
          });
          expect(started.sub.read().value, 'Team ACME');
          expect(lines, hasLength(1));
          expect(
            lines.single,
            matches(
              RegExp(
                r'^fespalier: dataCache of teams/acme could not save: fespalier_storage: the value saved under '
                r'fespalier:teams/acme is \d+ characters, more than maxSize \(60\), so it was not saved$',
              ),
            ),
          );
          expect(storage.length, 0);
          await stop(tester, started.container);
        },
      );

      testWidgets(
        'a family is keyed by its parts, and each key is saved on its own',
        (tester) async {
          final storage = await backend.open();
          final family = cachedDataFamily<String, int>(
            (ref, id) async {
              fetches++;
              return 'Product $id';
            },
            cache: DataCache<String>(encode: (v) => v, decode: (s) => s),
            name: 'products/\$id',
            keyParts: (id) => [id],
          );
          final first = ProviderContainer(
            overrides: [dataCacheStorage.overrideWithValue(storage)],
            retry: (count, error) => null,
          );
          addTearDown(first.dispose);
          first.listen(family(1), (_, _) {});
          first.listen(family(2), (_, _) {});
          await tester.pump();
          await tester.pump();
          await stop(tester, first);
          expect(storage.length, 2);

          final restarted = ProviderContainer(
            overrides: [
              dataCacheStorage.overrideWithValue(await backend.open()),
            ],
            retry: (count, error) => null,
          );
          addTearDown(restarted.dispose);
          final one = restarted.listen(family(1), (_, _) {});
          final three = restarted.listen(family(3), (_, _) {});
          expect(one.read().isFromCache, isTrue);
          expect(one.read().value, 'Product 1');
          expect(
            three.read().hasValue,
            isFalse,
            reason: 'nothing was saved for 3',
          );
          await tester.pump();
          await stop(tester, restarted);
        },
      );

      testWidgets('clear() is a sign-out: the next start shows nothing', (
        tester,
      ) async {
        await firstSession(tester);
        final storage = await backend.open();
        await storage.clear();
        final restarted = start(await backend.open(), team());
        final first = restarted.sub.read();
        expect(first.hasValue, isFalse);
        expect(first.isFromCache, isFalse);
        await tester.pump();
        await stop(tester, restarted.container);
      });
    });
  }
}
