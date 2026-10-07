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

  testWidgets(
    'the first frame shows bundled text, a fetch lands on the next pump',
    (tester) async {
      final source = GatedSource();
      await tester.pumpWidget(
        host(
          overrides: [
            translationsConfig.overrideWithValue(
              config(bundled: bundled, remote: source),
            ),
          ],
          home: const Probe('fr', 'hello'),
        ),
      );
      expect(find.text('Bonjour'), findsOneWidget);
      expect(source.calls, ['fr']);
      source.complete('fr', {'hello': 'Bonjour (CDN)'}, etag: 'e1');
      await tester.pump();
      expect(find.text('Bonjour (CDN)'), findsOneWidget);
    },
  );

  testWidgets('translator is a value, never an AsyncValue', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      host(
        overrides: [
          translationsConfig.overrideWithValue(config(bundled: bundled)),
        ],
        home: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(container.read(translator('fr')).tr('hello'), 'Bonjour');
  });

  testWidgets('one fetch per locale per container', (tester) async {
    final remote = FakeTranslations()..set('fr', {'hello': 'Salut'});
    await tester.pumpWidget(
      host(
        overrides: [
          translationsConfig.overrideWithValue(
            config(bundled: bundled, remote: remote),
          ),
        ],
        home: const Column(
          children: [
            Probe('fr', 'hello'),
            Probe('fr', 'hello'),
            Probe('en', 'hello'),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(remote.fetchCount('fr'), 1);
    expect(remote.fetchCount('en'), 1);
    expect(find.text('Salut'), findsNWidgets(2));
  });

  testWidgets('refreshOnResume refetches on appResumeSignal', (tester) async {
    final remote = FakeTranslations()..set('fr', {'hello': 'v1'});
    final container = ProviderContainer(
      overrides: [
        translationsConfig.overrideWithValue(
          config(bundled: bundled, remote: remote, refreshOnResume: true),
        ),
        appResumeSignal.overrideWith(RefetchSignal.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      host(container: container, home: const Probe('fr', 'hello')),
    );
    await tester.pump();
    expect(find.text('v1'), findsOneWidget);
    remote.set('fr', {'hello': 'v2'});
    container.read(appResumeSignal.notifier).fire();
    await tester.pump();
    await tester.pump();
    expect(remote.fetchCount('fr'), 2);
    expect(find.text('v2'), findsOneWidget);
  });

  testWidgets('without refreshOnResume a resume does not refetch', (
    tester,
  ) async {
    final remote = FakeTranslations()..set('fr', {'hello': 'v1'});
    final container = ProviderContainer(
      overrides: [
        translationsConfig.overrideWithValue(
          config(bundled: bundled, remote: remote),
        ),
        appResumeSignal.overrideWith(RefetchSignal.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      host(container: container, home: const Probe('fr', 'hello')),
    );
    await tester.pump();
    container.read(appResumeSignal.notifier).fire();
    await tester.pump();
    expect(remote.fetchCount('fr'), 1);
  });

  testWidgets('refreshOnReconnect refetches only after a failure', (
    tester,
  ) async {
    final remote = FakeTranslations()..set('fr', {'hello': 'v1'});
    final container = ProviderContainer(
      overrides: [
        translationsConfig.overrideWithValue(
          config(bundled: bundled, remote: remote),
        ),
        reconnectSignal.overrideWith(RefetchSignal.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      host(container: container, home: const Probe('fr', 'hello')),
    );
    await tester.pump();
    await tester.pump();
    // A reconnect after a success does nothing.
    container.read(reconnectSignal.notifier).fire();
    await tester.pump();
    await tester.pump();
    expect(remote.fetchCount('fr'), 1);

    // A failed fetch is retried on the next reconnect.
    final failing = FakeTranslations()..offline();
    final second = ProviderContainer(
      overrides: [
        translationsConfig.overrideWithValue(
          config(bundled: bundled, remote: failing),
        ),
        reconnectSignal.overrideWith(RefetchSignal.new),
      ],
    );
    addTearDown(second.dispose);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      host(container: second, home: const Probe('fr', 'hello')),
    );
    await tester.pump();
    await tester.pump();
    expect(failing.fetchCount('fr'), 1);
    expect(find.text('Bonjour'), findsOneWidget);
    failing
      ..online()
      ..set('fr', {'hello': 'Retry'});
    second.read(reconnectSignal.notifier).fire();
    await tester.pump();
    await tester.pump();
    expect(failing.fetchCount('fr'), 2);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a 304 keeps what is shown and sends the ETag it has', (
    tester,
  ) async {
    final source = GatedSource();
    final container = ProviderContainer(
      overrides: [
        translationsConfig.overrideWithValue(
          config(bundled: bundled, remote: source, refreshOnResume: true),
        ),
        appResumeSignal.overrideWith(RefetchSignal.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      host(container: container, home: const Probe('fr', 'hello')),
    );
    source.complete('fr', {'hello': 'v1'}, etag: 'E');
    await tester.pump();
    await tester.pump();
    source.rearm('fr');
    container.read(appResumeSignal.notifier).fire();
    await tester.pump();
    expect(source.etags, [null, 'E']);
  });

  testWidgets('FakeTranslations.strict fails on a missing key', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final old = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = old);
    await tester.pumpWidget(
      host(
        overrides: fakeTranslations(
          bundled: bundled,
          remote: FakeTranslations.strict(),
        ),
        home: const Probe('en', 'typo'),
      ),
    );
    expect(errors, isNotEmpty);
    expect(errors.first.library, 'fespalier_tolgee');
  });
}
