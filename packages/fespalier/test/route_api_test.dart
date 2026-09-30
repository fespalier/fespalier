import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads after 100 ms and counts how often it ran. autoDispose, like the
/// providers fespalier generates.
var loads = 0;
final slow = FutureProvider.autoDispose.family<String, int>((ref, n) async {
  loads++;
  await Future<void>.delayed(const Duration(milliseconds: 100));
  if (n < 0) throw StateError('negative');
  return 'value $n';
});

/// A widget to take a [WidgetRef] from.
class Probe extends ConsumerWidget {
  const Probe({super.key, this.body});

  final Widget Function(WidgetRef ref)? body;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      body?.call(ref) ?? const SizedBox();
}

Future<(WidgetRef, ProviderContainer)> boot(WidgetTester tester) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Probe()),
    ),
  );
  return (tester.element(find.byType(Probe)) as WidgetRef, container);
}

void main() {
  setUp(() => loads = 0);

  group('nearestNotFound', () {
    Widget scoped(Uri uri, {String base = '/'}) => nearestNotFound(
          uri,
          base,
          [
            (['a', ':id', 'deep'], (uri) => Text('deep ${uri.path}'), caseSensitive: true),
            (['a', ':id'], (uri) => Text('item ${uri.path}'), caseSensitive: true),
            (['a'], (uri) => Text('a ${uri.path}'), caseSensitive: true),
          ],
          (uri) => Text('root ${uri.path}'),
        );

    String shown(Widget w) => (w as Text).data!;

    test('the deepest folder the path is under wins', () {
      expect(shown(scoped(Uri.parse('/a/1/deep/x'))), 'deep /a/1/deep/x');
      expect(shown(scoped(Uri.parse('/a/1/other'))), 'item /a/1/other');
      expect(shown(scoped(Uri.parse('/a/1'))), 'item /a/1');
      expect(shown(scoped(Uri.parse('/a/x/y/z'))), 'item /a/x/y/z');
      expect(shown(scoped(Uri.parse('/a'))), 'a /a');
    });

    test('elsewhere the root one', () {
      expect(shown(scoped(Uri.parse('/b/1'))), 'root /b/1');
      expect(shown(scoped(Uri.parse('/'))), 'root /');
    });

    test('a mount prefix is skipped, and other prefixes are not ours', () {
      expect(shown(scoped(Uri.parse('/shop/a/1'), base: '/shop')),
          'item /shop/a/1');
      expect(shown(scoped(Uri.parse('/other/a/1'), base: '/shop')),
          'root /other/a/1');
      expect(shown(scoped(Uri.parse('/shop'), base: '/shop')), 'root /shop');
    });
  });

  group('DataRef', () {
    testWidgets('readData keeps an autoDispose provider alive while it loads',
        (tester) async {
      final (ref, container) = await boot(tester);
      final value = ref.readData(slow(1));
      await tester.pump(const Duration(milliseconds: 150));
      expect(await value, 'value 1');
      expect(loads, 1);
      // Nothing keeps it after that.
      await tester.pump();
      expect(container.exists(slow(1)), isFalse);
    });

    testWidgets('readData throws what the provider threw', (tester) async {
      final (ref, _) = await boot(tester);
      final caught = expectLater(ref.readData(slow(-1)), throwsStateError);
      await tester.pump(const Duration(milliseconds: 150));
      await caught;
    });

    testWidgets('prefetchData loads now and keeps the result for keepFor',
        (tester) async {
      final (ref, container) = await boot(tester);
      ref.prefetchData(slow(2), keepFor: const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 150));
      expect(loads, 1);

      // Still there a second later, so a watcher gets it without loading.
      await tester.pump(const Duration(seconds: 1));
      expect(container.exists(slow(2)), isTrue);
      expect(container.read(slow(2)).value, 'value 2');
      expect(loads, 1);

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(container.exists(slow(2)), isFalse);
    });

    testWidgets('prefetchData does not keep an error', (tester) async {
      final (ref, container) = await boot(tester);
      ref.prefetchData(slow(-1));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(container.exists(slow(-1)), isFalse);
      await tester.pump(prefetchKeepAlive);
    });

    testWidgets('a zero keepFor starts the load and keeps nothing',
        (tester) async {
      final (ref, container) = await boot(tester);
      ref.prefetchData(slow(3), keepFor: Duration.zero);
      await tester.pump(const Duration(milliseconds: 150));
      expect(container.exists(slow(3)), isFalse);
    });
  });

  group('SectionView', () {
    testWidgets('builds once the provider has a value', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: SectionView(
              watch: (ref) => ref.watch(slow(5)),
              data: (v) => Text('got $v'),
            ),
          ),
        ),
      );
      expect(find.textContaining('got'), findsNothing);
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('got value 5'), findsOneWidget);
    });
  });

  group('testing.dart', () {
    GoRouter router() => GoRouter(routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => context.go('/next?x=1'),
                child: Text('home ${ref.watch(label)}'),
              ),
            ),
          ),
          GoRoute(path: '/next', builder: (_, __) => const Text('next')),
        ]);

    testWidgets('pumpRouter applies overrides and settles', (tester) async {
      final container = await pumpRouter(
        tester,
        router(),
        overrides: [label.overrideWithValue('fake')],
      );
      expect(find.text('home fake'), findsOneWidget);
      expect(container.read(label), 'fake');
      expect(currentLocation(tester), '/');
    });

    testWidgets('currentLocation follows navigation, query included',
        (tester) async {
      await pumpRouter(tester, router());
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(find.text('next'), findsOneWidget);
      expect(currentLocation(tester), '/next?x=1');
    });

    testWidgets('pumpRouter can use your own container', (tester) async {
      final mine = ProviderContainer(overrides: [label.overrideWithValue('mine')]);
      addTearDown(mine.dispose);
      final used = await pumpRouter(tester, router(), container: mine);
      expect(identical(used, mine), isTrue);
      expect(find.text('home mine'), findsOneWidget);
    });
  });
}

final label = Provider((ref) => 'real');
