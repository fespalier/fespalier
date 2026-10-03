// Who holds a provider, as DevTools asks (since 0.8.1): the views, the prefetch handles and the
// `RouteLink` preloads fespalier makes, the listeners of a provider it built, and the app's own
// providers that a `data.dart` returns or selects.
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/devtools/devtools.dart';
import 'package:fespalier/src/devtools/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `d7` is a data.dart that fespalier wraps; `d8` and `d9` select or return a provider.
String tree() => jsonEncode({
  'protocol': 1,
  'package': 'shop',
  'appDir': 'lib/app',
  'items': <Object?>[],
  'sites': {
    'd7': {'kind': 'data', 'file': 'products/\$id/data.dart', 'traced': true},
    'd8': {'kind': 'data', 'file': 'items/\$id/data.dart', 'traced': false},
    'd9': {'kind': 'data', 'file': 'about/data.dart', 'traced': false},
  },
});

UrlMatch? matchUrl(Uri uri) => null;

/// A provider fespalier built (the function form), keyed by id.
final built = FutureProvider.autoDispose.family<String, int>(
  (ref, id) => traceData(ref, 'd7', id, Future.value('item $id')),
);

/// The app's own provider, which `d8` selects by id (a closure: the map does not list it).
var appRuns = 0;
final appItem = FutureProvider.autoDispose.family<String, int>(
  (ref, id) async => 'app $id #${++appRuns}',
);

/// The app's own provider that `d9` returns.
final appOne = FutureProvider.autoDispose<String>((ref) async => 'one');

/// What the generated `_devToolsProviders` lists: the family of `d7`, and the provider of `d9`.
Map<Object, String> providers() => {built: 'd7', appOne: 'd9'};

final class _Item extends TypedLocation {
  const _Item(this.id);
  final int id;

  @override
  String get location => '/items/$id';

  @override
  PrefetchHandle preload(WidgetRef ref, {Duration? keepFor}) =>
      ref.prefetchAll([built(id)], keepFor: keepFor);
}

Widget view(
  String site,
  ProviderListenable<AsyncValue<String>> Function() provider,
) => DataView<String>(
  watch: (ref) => watchData(ref, site, provider()),
  refresh: (ref) {},
  data: (d) => Text(d),
  loading: () => const Text('loading'),
  error: (e, st, retry) => const Text('error'),
);

Widget app(Widget home) => ProviderScope(
  child: MaterialApp(home: Material(child: home)),
);

List<DataRecord> get records => [
  for (final (kind, payload) in debugDevToolsEvents!)
    if (kind == DevToolsEvents.data)
      DataRecord.fromJson(
        payload[DevToolsEventPayload.record]! as Map<String, Object?>,
      ),
];

Future<List<DataRecord>> data() async => SnapshotRecord.fromJson(
  await debugDevToolsCall(DevToolsMethods.snapshot),
).data;

Future<HoldersRecord> holders(int id) async => HoldersRecord.fromJson(
  await debugDevToolsCall(DevToolsMethods.holders, {'id': '$id'}),
);

/// The one record of [site] (there is one in these tests).
Future<DataRecord> recordOf(String site) async =>
    (await data()).singleWhere((d) => d.site == site);

void main() {
  setUp(() {
    debugDevToolsReset();
    debugDevToolsEvents = [];
    appRuns = 0;
    devToolsRegister(tree: tree, matchUrl: matchUrl, providers: providers);
  });
  tearDown(() {
    debugDevToolsReset();
    debugDevToolsEvents = null;
  });

  test(
    'holders is a feature, and answers found: false for an unknown id',
    () async {
      final hello = HelloRecord.fromJson(
        await debugDevToolsCall(DevToolsMethods.hello),
      );
      expect(
        hello.features,
        containsAll([DevToolsFeatures.holders, DevToolsFeatures.watched]),
      );
      expect(await debugDevToolsCall(DevToolsMethods.holders, {'id': '99'}), {
        'protocol': 1,
        'id': 99,
        'found': false,
      });
      final bad = await debugDevToolsCall(DevToolsMethods.holders, {'id': 'x'});
      expect(bad['errorDetail'], 'parameter `id` is not a number: `x`');
      final missing = await debugDevToolsCall(DevToolsMethods.holders);
      expect(missing['errorDetail'], 'missing parameter `id`');
    },
  );

  group('a provider fespalier built', () {
    testWidgets('the page view holds it, and leaving releases it', (
      tester,
    ) async {
      await tester.pumpWidget(app(view('d7', () => built(3))));
      await tester.pump();
      expect(find.text('item 3'), findsOneWidget);
      var record = await recordOf('d7');
      expect(record.via, DataVia.build);
      expect(record.listeners, 1);
      var answer = await holders(record.id);
      expect(answer.found, isTrue);
      expect(answer.alive, isTrue);
      expect(answer.listeners, 1);
      expect(answer.others, 0);
      expect([for (final h in answer.holders) h.kind], [HolderKind.view]);
      expect(answer.holders.single.keepFor, isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      record = await recordOf('d7');
      expect(record.state, DataState.disposed);
      expect(record.listeners, 0);
      answer = await holders(record.id);
      expect(answer.holders, isEmpty);
      expect(answer.listeners, 0);
      expect(answer.alive, isFalse);
    });

    testWidgets('a section view is a section holder', (tester) async {
      await tester.pumpWidget(
        app(
          SectionView<String>(
            watch: (ref) => watchData(ref, 'd7', built(1)),
            data: (d) => Text(d),
          ),
        ),
      );
      await tester.pump();
      // Nothing built it yet but the section's own watch, which is the only listener.
      final answer = await holders((await recordOf('d7')).id);
      expect([for (final h in answer.holders) h.kind], [HolderKind.section]);
      expect(answer.listeners, 1);
    });

    testWidgets('a prefetch before any page is a holder of the right record, '
        'with how long it is kept', (tester) async {
      late WidgetRef captured;
      await tester.pumpWidget(
        app(
          Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return const SizedBox();
            },
          ),
        ),
      );
      final handle = captured.prefetchAll([
        built(3),
      ], keepFor: const Duration(seconds: 30));
      await tester.pump();
      final record = await recordOf('d7');
      expect(record.key, const Shown('int', '3'));
      var answer = await holders(record.id);
      expect([for (final h in answer.holders) h.kind], [HolderKind.prefetch]);
      expect(answer.holders.single.keepFor, 30000);
      expect(answer.listeners, 1);
      expect(answer.others, 0);
      handle.close();
      await tester.pump();
      answer = await holders(record.id);
      expect(answer.holders, isEmpty);
      expect(answer.listeners, 0);
    });

    testWidgets('a prefetch with no keepFor is kept until closed', (
      tester,
    ) async {
      late WidgetRef captured;
      await tester.pumpWidget(
        app(
          Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return const SizedBox();
            },
          ),
        ),
      );
      final handle = captured.prefetchData(built(4));
      addTearDown(handle.close);
      await tester.pump();
      final answer = await holders((await recordOf('d7')).id);
      expect(answer.holders.single.kind, HolderKind.prefetch);
      expect(answer.holders.single.keepFor, isNull);
    });

    testWidgets('a RouteLink preload is a link holder', (tester) async {
      await tester.pumpWidget(
        app(
          RouteLink(
            to: const _Item(5),
            preload: Preload.visible,
            builder: (context, follow) =>
                TextButton(onPressed: follow, child: const Text('item')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final record = await recordOf('d7');
      expect(record.key, const Shown('int', '5'));
      final answer = await holders(record.id);
      expect([for (final h in answer.holders) h.kind], [HolderKind.link]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect((await holders(record.id)).holders, isEmpty);
    });

    testWidgets('a ref.watch of the app is an other listener, counted', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          Column(
            children: [
              view('d7', () => built(3)),
              Consumer(
                builder: (context, ref, _) =>
                    Text('mine ${ref.watch(built(3)).value}'),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      final record = await recordOf('d7');
      expect(record.listeners, 2);
      final answer = await holders(record.id);
      expect([for (final h in answer.holders) h.kind], [HolderKind.view]);
      expect(answer.others, 1);
    });

    testWidgets('a nested ProviderScope without overrides: the view holds the '
        'record of the root container', (tester) async {
      await tester.pumpWidget(
        app(ProviderScope(child: view('d7', () => built(3)))),
      );
      await tester.pump();
      final answer = await holders((await recordOf('d7')).id);
      expect([for (final h in answer.holders) h.kind], [HolderKind.view]);
      expect(answer.listeners, 1);
    });

    testWidgets('an invalidation keeps the count', (tester) async {
      late WidgetRef captured;
      await tester.pumpWidget(
        app(
          Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return view('d7', () => built(3));
            },
          ),
        ),
      );
      await tester.pump();
      captured.invalidate(built(3));
      await tester.pump();
      await tester.pump();
      final record = await recordOf('d7');
      expect(record.builds, 2);
      expect(record.listeners, 1);
      expect((await holders(record.id)).others, 0);
    });
  });

  group('the app\'s own provider', () {
    testWidgets('a selected family is a watch record: its provider, its '
        'state, and the view that holds it', (tester) async {
      await tester.pumpWidget(app(view('d8', () => appItem(3))));
      var record = await recordOf('d8');
      expect(record.via, DataVia.watch);
      expect(record.state, DataState.loading);
      expect(record.key, const Shown('int', '3'));
      expect(record.provider!.text, contains('3'));
      expect(record.builds, 0);
      expect(record.listeners, isNull);
      await tester.pump();
      await tester.pump();
      record = await recordOf('d8');
      expect(record.state, DataState.data);
      expect(record.value, const Shown('String', 'app 3 #1'));
      final answer = await holders(record.id);
      expect(answer.alive, isTrue);
      expect(answer.listeners, isNull);
      expect(answer.others, isNull);
      expect([for (final h in answer.holders) h.kind], [HolderKind.view]);
      expect(
        [for (final d in records) d.state],
        [DataState.loading, DataState.data],
      );

      // The scope stays: it is the page that goes. Riverpod drops an unlistened provider in a
      // microtask after the frame.
      await tester.pumpWidget(app(const SizedBox()));
      await tester.pump();
      await tester.idle();
      final gone = await holders(record.id);
      expect(gone.alive, isFalse);
      expect(gone.holders, isEmpty);
      expect((await recordOf('d8')).state, DataState.disposed);
    });

    testWidgets('the provider form is followed too, from the providers map', (
      tester,
    ) async {
      late WidgetRef captured;
      await tester.pumpWidget(
        app(
          Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return const SizedBox();
            },
          ),
        ),
      );
      // Prefetched before any page: nothing to show yet, but the holder is kept.
      final handle = captured.prefetchData(appOne);
      addTearDown(handle.close);
      await tester.pump();
      expect(await data(), isEmpty);
      await tester.pumpWidget(
        app(
          Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return view('d9', () => appOne);
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final record = await recordOf('d9');
      expect(record.via, DataVia.watch);
      expect(record.key, isNull);
      expect(record.state, DataState.data);
      final answer = await holders(record.id);
      expect(
        [for (final h in answer.holders) h.kind],
        [HolderKind.prefetch, HolderKind.view],
      );
    });

    testWidgets('invalidate runs the app\'s provider again', (tester) async {
      await tester.pumpWidget(app(view('d8', () => appItem(3))));
      await tester.pump();
      await tester.pump();
      expect(appRuns, 1);
      final id = (await recordOf('d8')).id;
      expect(
        await debugDevToolsCall(DevToolsMethods.invalidate, {'id': '$id'}),
        {'protocol': 1, 'ok': true},
      );
      await tester.pump();
      await tester.pump();
      expect(appRuns, 2);
      expect((await recordOf('d8')).value, const Shown('String', 'app 3 #2'));
    });

    testWidgets('a .select(...) is followed, but cannot be invalidated or '
        'asked whether it is alive', (tester) async {
      await tester.pumpWidget(
        app(view('d8', () => appItem(3).select((AsyncValue<String> v) => v))),
      );
      await tester.pump();
      await tester.pump();
      final record = await recordOf('d8');
      expect(record.via, DataVia.watch);
      expect(record.state, DataState.data);
      expect(
        await holders(record.id),
        isA<HoldersRecord>().having((h) => h.alive, 'alive', isNull),
      );
      expect(
        await debugDevToolsCall(DevToolsMethods.invalidate, {
          'id': '${record.id}',
        }),
        {'protocol': 1, 'ok': false},
      );
    });

    testWidgets('a prefetch of a selected family before any view is attached '
        'when the view first watches it', (tester) async {
      late WidgetRef captured;
      await tester.pumpWidget(
        app(
          Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return const SizedBox();
            },
          ),
        ),
      );
      final handle = captured.prefetchData(appItem(5));
      addTearDown(handle.close);
      await tester.pump();
      expect(await data(), isEmpty);
      await tester.pumpWidget(
        app(
          Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return view('d8', () => appItem(5));
            },
          ),
        ),
      );
      await tester.pump();
      final answer = await holders((await recordOf('d8')).id);
      expect(
        [for (final h in answer.holders) h.kind],
        [HolderKind.prefetch, HolderKind.view],
      );
    });

    testWidgets('a rebuild with the same value records nothing more', (
      tester,
    ) async {
      late StateSetter set;
      await tester.pumpWidget(
        app(
          StatefulBuilder(
            builder: (context, setState) {
              set = setState;
              return view('d8', () => appItem(3));
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final before = records.length;
      set(() {});
      await tester.pump();
      set(() {});
      await tester.pump();
      expect(records, hasLength(before));
    });
  });

  testWidgets('clear all forgets what was prefetched before a view', (
    tester,
  ) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      app(
        Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    final handle = captured.prefetchData(appItem(6));
    addTearDown(handle.close);
    await debugDevToolsCall(DevToolsMethods.clear, {'what': ClearWhat.all});
    await tester.pumpWidget(app(view('d8', () => appItem(6))));
    await tester.pump();
    final answer = await holders((await recordOf('d8')).id);
    expect([for (final h in answer.holders) h.kind], [HolderKind.view]);
  });
}
