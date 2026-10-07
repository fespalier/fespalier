import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:fespalier_tolgee/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  const bundled = {
    'en': {'hello': 'Hello'},
    'fr': {'hello': 'Bonjour'},
  };

  testWidgets('first launch offline shows bundled text, no error, no timers', (
    tester,
  ) async {
    final remote = FakeTranslations()..offline();
    await tester.pumpWidget(
      host(
        overrides: [
          translationsConfig.overrideWithValue(
            config(bundled: bundled, remote: remote),
          ),
          dataCacheStorage.overrideWithValue(MemoryDataStorage()),
        ],
        home: const Probe('fr', 'hello'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Bonjour'), findsOneWidget);
    expect(remote.fetchCount('fr'), 1);
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'a restart with the same storage shows the cached text on the first frame',
    (tester) async {
      final storage = MemoryDataStorage();
      final remote = FakeTranslations()..set('fr', {'hello': 'Salut (CDN)'});
      Widget app(TranslationSource? source) => host(
        overrides: [
          translationsConfig.overrideWithValue(
            config(bundled: bundled, remote: source),
          ),
          dataCacheStorage.overrideWithValue(storage),
        ],
        home: const Probe('fr', 'hello'),
      );

      await tester.pumpWidget(app(remote));
      await tester.pump();
      await tester.pump();
      expect(find.text('Salut (CDN)'), findsOneWidget);

      // A new container, and the network is gone: the cache answers on the first frame.
      await tester.pumpWidget(const SizedBox());
      final offline = FakeTranslations()..offline();
      await tester.pumpWidget(app(offline));
      expect(find.text('Salut (CDN)'), findsOneWidget);
      await tester.pump();
      expect(find.text('Salut (CDN)'), findsOneWidget);
    },
  );

  testWidgets('a cached entry past cacheMaxAge is ignored', (tester) async {
    final storage = MemoryDataStorage();
    final start = DateTime.utc(2030, 1, 1);
    Widget app(TranslationSource? source) => host(
      overrides: [
        translationsConfig.overrideWithValue(
          config(
            bundled: bundled,
            remote: source,
            cacheMaxAge: const Duration(days: 1),
          ),
        ),
        dataCacheStorage.overrideWithValue(storage),
      ],
      home: const Probe('fr', 'hello'),
    );

    await withClock(Clock.fixed(start), () async {
      await tester.pumpWidget(
        app(FakeTranslations()..set('fr', {'hello': 'Salut (CDN)'})),
      );
      await tester.pump();
      await tester.pump();
    });
    await tester.pumpWidget(const SizedBox());

    await withClock(Clock.fixed(start.add(const Duration(days: 2))), () async {
      await tester.pumpWidget(app(FakeTranslations()..offline()));
      expect(find.text('Bonjour'), findsOneWidget);
    });
  });

  testWidgets(
    'a 304 writes the cache entry again, so its age runs from the check',
    (tester) async {
      final storage = MemoryDataStorage();
      final start = DateTime.utc(2030, 1, 1);
      Widget app(TranslationSource source) => host(
        overrides: [
          translationsConfig.overrideWithValue(
            config(
              bundled: bundled,
              remote: source,
              cacheMaxAge: const Duration(days: 10),
            ),
          ),
          dataCacheStorage.overrideWithValue(storage),
        ],
        home: const Probe('fr', 'hello'),
      );
      await withClock(Clock.fixed(start), () async {
        await tester.pumpWidget(
          app(FakeTranslations()..set('fr', {'hello': 'Salut (CDN)'})),
        );
        await tester.pump();
        await tester.pump();
      });
      await tester.pumpWidget(const SizedBox());
      // Day 8: the source answers "not modified" (it is sent the cached ETag).
      await withClock(
        Clock.fixed(start.add(const Duration(days: 8))),
        () async {
          await tester.pumpWidget(app(FakeTranslations()..notModified()));
          await tester.pump();
          await tester.pump();
        },
      );
      await tester.pumpWidget(const SizedBox());
      // Day 15 is past the first write's 10 days, but not the refreshed one's.
      await withClock(
        Clock.fixed(start.add(const Duration(days: 15))),
        () async {
          await tester.pumpWidget(app(FakeTranslations()..offline()));
          expect(find.text('Salut (CDN)'), findsOneWidget);
        },
      );
    },
  );
}
