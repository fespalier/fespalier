// matchUrl (what the generated AppRoutes.matchUrl / dataAt / match are built on)
// and the PrefetchHandle that prefetch returns.

import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class ProductRoute extends TypedLocation {
  const ProductRoute({required this.id});
  final int id;
  @override
  String get location => '/products/$id';
}

final class DocsRoute extends TypedLocation {
  const DocsRoute({required this.rest});
  final List<String> rest;
  @override
  String get location => '/docs${restPath(rest)}';
}

final class AboutRoute extends TypedLocation {
  const AboutRoute();
  @override
  String get location => '/about';
}

var loads = 0;
final product = FutureProvider.autoDispose.family<String, int>((ref, n) async {
  loads++;
  await Future<void>.delayed(const Duration(milliseconds: 100));
  if (n < 0) throw StateError('negative');
  return 'product $n';
});

/// The matchers `fsp gen` writes, by hand: the specific route first.
final matchers = <RouteMatcher>[
  RouteMatcher(['about'], (s) => UrlMatch(s.uri, const AboutRoute(), {}, [])),
  RouteMatcher(['products', ':id'], (s) {
    final p = (id: Segment.asInt(s, 'id'));
    return UrlMatch(s.uri, ProductRoute(id: p.id), {'id': p.id}, [
      product(p.id),
    ]);
  }),
  RouteMatcher(['docs', '*rest?'], (s) {
    final rest = Segment.asRest(s, 'rest');
    return UrlMatch(s.uri, DocsRoute(rest: rest), {'rest': rest}, []);
  }),
];

UrlMatch? at(
  String location, {
  String base = '/',
  bool caseSensitive = true,
}) => matchRoutes(
  Uri.parse(location),
  base,
  matchers,
  caseSensitive: caseSensitive,
);

class Probe extends ConsumerWidget {
  const Probe({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => const SizedBox();
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

  group('matchUrl', () {
    test('parses the segments into the typed route and the params', () {
      final m = at('/products/42')!;
      expect(m.type, ProductRoute);
      expect((m.route as ProductRoute).id, 42);
      expect(m.params, {'id': 42});
      expect(m.data.single, product(42));
      expect(m.uri, Uri.parse('/products/42'));
    });

    test('a segment that does not parse is no match', () {
      expect(at('/products/abc'), isNull);
    });

    test('an unknown path is no match', () {
      expect(at('/nope'), isNull);
      expect(at('/products'), isNull);
      expect(at('/products/1/2'), isNull);
    });

    test('a trailing slash and a query do not matter', () {
      expect(at('/products/7/?x=1')!.params, {'id': 7});
      expect(at('/about/')!.type, AboutRoute);
    });

    test('an optional catch-all takes none or several parts', () {
      expect(at('/docs')!.params, {'rest': <String>[]});
      expect(at('/docs/a/b%2Fc/d')!.params, {
        'rest': ['a', 'b/c', 'd'],
      });
    });

    test('the mount point is stripped; other prefixes are not ours', () {
      expect(at('/shop/products/5', base: '/shop')!.params, {'id': 5});
      expect(at('/shop/docs/a/b', base: '/shop')!.params, {
        'rest': ['a', 'b'],
      });
      expect(at('/products/5', base: '/shop'), isNull);
      expect(at('/shop', base: '/shop'), isNull);
    });

    test('case matters unless it is switched off', () {
      expect(at('/Products/5'), isNull);
      expect(at('/Products/5', caseSensitive: false)!.type, ProductRoute);
      expect(
        at('/SHOP/products/5', base: '/shop', caseSensitive: false),
        isNotNull,
      );
    });
  });

  group('PrefetchHandle', () {
    testWidgets('keeps the provider alive until it is closed', (tester) async {
      final (ref, container) = await boot(tester);
      final handle = ref.prefetchData(product(1));
      await tester.pump(const Duration(milliseconds: 150));
      expect(loads, 1);

      // A minute on, with nothing watching, the warm value is still there.
      await tester.pump(const Duration(minutes: 1));
      expect(container.exists(product(1)), isTrue);
      expect(container.read(product(1)).value, 'product 1');
      expect(loads, 1);
      expect(handle.isClosed, isFalse);

      handle.close();
      await tester.pump();
      expect(container.exists(product(1)), isFalse);
      expect(handle.isClosed, isTrue);
      // Closing twice is fine.
      handle.close();
    });

    testWidgets('keepFor closes it on its own, and close() does not wait', (
      tester,
    ) async {
      final (ref, container) = await boot(tester);
      final timed = ref.prefetchData(
        product(2),
        keepFor: const Duration(seconds: 5),
      );
      final early = ref.prefetchData(
        product(3),
        keepFor: const Duration(seconds: 5),
      );
      await tester.pump(const Duration(milliseconds: 150));
      early.close();
      await tester.pump();
      expect(container.exists(product(3)), isFalse);
      expect(container.exists(product(2)), isTrue);

      await tester.pump(const Duration(seconds: 6));
      expect(timed.isClosed, isTrue);
      expect(container.exists(product(2)), isFalse);
    });

    testWidgets('a provider stays while any handle to it is open', (
      tester,
    ) async {
      final (ref, container) = await boot(tester);
      final a = ref.prefetchData(product(4));
      final b = ref.prefetchData(product(4));
      await tester.pump(const Duration(milliseconds: 150));
      expect(loads, 1);
      a.close();
      await tester.pump();
      expect(container.exists(product(4)), isTrue);
      b.close();
      await tester.pump();
      expect(container.exists(product(4)), isFalse);
    });

    testWidgets('a failed load closes the handle and keeps nothing', (
      tester,
    ) async {
      final (ref, container) = await boot(tester);
      final handle = ref.prefetchData(product(-1));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(handle.isClosed, isTrue);
      expect(container.exists(product(-1)), isFalse);
    });

    testWidgets('prefetchAll closes every provider with one handle', (
      tester,
    ) async {
      final (ref, container) = await boot(tester);
      final handle = ref.prefetchAll([product(5), product(6)]);
      await tester.pump(const Duration(milliseconds: 150));
      expect(loads, 2);
      await tester.pump(const Duration(minutes: 1));
      expect(container.exists(product(5)), isTrue);
      expect(container.exists(product(6)), isTrue);

      handle.close();
      await tester.pump();
      expect(container.exists(product(5)), isFalse);
      expect(container.exists(product(6)), isFalse);
      expect(ref.prefetchAll(const []).isClosed, isTrue);
    });

    testWidgets('warms what a match found: the page then finds it loaded', (
      tester,
    ) async {
      final (ref, container) = await boot(tester);
      final handle = ref.prefetchAll(at('/products/9')!.data);
      await tester.pump(const Duration(milliseconds: 150));
      expect(container.read(product(9)).value, 'product 9');
      expect(loads, 1);
      handle.close();
    });
  });
}
