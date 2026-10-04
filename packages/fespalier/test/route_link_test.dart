import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher/link.dart' as url;

import 'support/floor.dart';

/// How often a provider's body ran; autoDispose, like the generated ones.
var loads = 0;
final item = FutureProvider.autoDispose.family<String, int>((ref, n) async {
  loads++;
  if (n < 0) throw StateError('negative');
  return 'value $n';
});

/// What a generated route with data looks like: it preloads its provider.
final class ItemRoute extends TypedLocation {
  const ItemRoute(this.id);
  final int id;

  @override
  String get location => '/items/$id';

  @override
  String locationFor(String? locale) =>
      locale == 'fr' ? '/articles/$id' : location;

  @override
  PrefetchHandle preload(WidgetRef ref, {Duration? keepFor}) =>
      ref.prefetchAll([item(id)], keepFor: keepFor);
}

/// A route whose page.dart is deferred: it preloads its code (a library whose load the
/// test controls), and counts how often it was asked to.
final class CodeRoute extends TypedLocation {
  const CodeRoute();

  static var preloads = 0;
  static final completer = Completer<void>();
  static final library = DeferredLibrary(
    () => completer.future,
    'code/page.dart',
    loadsInFakeAsync: true,
  );

  @override
  String get location => '/code';

  @override
  PrefetchHandle preload(WidgetRef ref, {Duration? keepFor}) {
    preloads++;
    library.preload();
    return ref.prefetchAll([item(7)], keepFor: keepFor);
  }
}

/// A route without data: it inherits the no-op.
final class AboutRoute extends TypedLocation {
  const AboutRoute();

  @override
  String get location => '/about';
}

/// A route mounted below a prefix, as `AppRoutes.mount(at: '/shop')` writes it.
final class ShopItemRoute extends TypedLocation {
  const ShopItemRoute(this.id);
  final int id;

  @override
  String get location => '/shop/items/$id';
}

late int redirects;

GoRouter buildRouter(Widget home) => GoRouter(
  redirect: (context, state) {
    redirects++;
    return null;
  },
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => Material(
        child: Align(alignment: Alignment.topLeft, child: home),
      ),
    ),
    GoRoute(
      path: '/items/:id',
      builder: (context, state) => Text('item ${state.pathParameters['id']}'),
    ),
    GoRoute(path: '/about', builder: (context, state) => const Text('about')),
    GoRoute(
      path: '/shop/items/:id',
      builder: (context, state) => Text('shop ${state.pathParameters['id']}'),
    ),
  ],
);

Widget linkTile(
  TypedLocation to,
  String label, {
  Preload? preload,
  LinkMethod method = LinkMethod.go,
}) => RouteLink(
  to: to,
  preload: preload,
  method: method,
  builder: (context, follow) => ListTile(title: Text(label), onTap: follow),
);

Future<(GoRouter, ProviderContainer)> boot(
  WidgetTester tester,
  Widget home, {
  Widget Function(Widget child)? scope,
}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final router = buildRouter(home);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: scope == null ? null : (context, child) => scope(child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (router, container);
}

Future<TestGesture> mouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: const Offset(790, 590));
  addTearDown(gesture.removePointer);
  return gesture;
}

/// Moves the pointer off the screen's corner and onto [target]: a fresh enter.
Future<void> hover(
  WidgetTester tester,
  TestGesture pointer,
  Finder target,
) async {
  await pointer.moveTo(const Offset(790, 590));
  await tester.pump();
  await pointer.moveTo(tester.getCenter(target));
  await tester.pump();
}

void main() {
  setUp(() {
    loads = 0;
    redirects = 0;
  });

  group('following', () {
    testWidgets('a click goes to the route', (tester) async {
      await boot(tester, linkTile(const ItemRoute(2), 'Two'));
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/items/2');
      expect(find.text('item 2'), findsOneWidget);
    });

    testWidgets('go replaces the whole stack', (tester) async {
      final (router, _) = await boot(
        tester,
        linkTile(const ItemRoute(2), 'Two'),
      );
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      expect(router.canPop(), isFalse);
    });

    testWidgets('push puts the page on top and back returns', (tester) async {
      final (router, _) = await boot(
        tester,
        linkTile(const ItemRoute(2), 'Two', method: LinkMethod.push),
      );
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/items/2');
      expect(router.canPop(), isTrue);
      router.pop();
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/');
      expect(find.text('Two'), findsOneWidget);
    });

    testWidgets('replace takes the place of the page', (tester) async {
      final (router, _) = await boot(
        tester,
        linkTile(const ItemRoute(2), 'Two', method: LinkMethod.replace),
      );
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/items/2');
      expect(router.canPop(), isFalse);
    });

    testWidgets('a uri: link follows its location, query included', (
      tester,
    ) async {
      await boot(
        tester,
        RouteLink(
          uri: Uri.parse('/items/3?tab=a'),
          builder: (context, follow) =>
              ListTile(title: const Text('Three'), onTap: follow),
        ),
      );
      await tester.tap(find.text('Three'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/items/3?tab=a');
    });

    testWidgets('follow works from a button too (a keyboard activation)', (
      tester,
    ) async {
      await boot(
        tester,
        RouteLink(
          to: const AboutRoute(),
          builder: (context, follow) =>
              TextButton(onPressed: follow, child: const Text('About')),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('about'), findsOneWidget);
    });
  });

  group('the link itself', () {
    testWidgets('href is the location, mount prefix included', (tester) async {
      await boot(tester, linkTile(const ShopItemRoute(4), 'Four'));
      final link = tester.widget<url.Link>(find.byType(url.Link));
      expect(link.uri, Uri.parse('/shop/items/4'));
      await tester.tap(find.text('Four'));
      await tester.pumpAndSettle();
      expect(find.text('shop 4'), findsOneWidget);
    });

    testWidgets('a locale picks the localized spelling', (tester) async {
      await boot(
        tester,
        RouteLink(
          to: const ItemRoute(2),
          locale: 'fr',
          builder: (context, follow) => ListTile(onTap: follow),
        ),
      );
      expect(
        tester.widget<url.Link>(find.byType(url.Link)).uri,
        Uri.parse('/articles/2'),
      );
    });

    testWidgets('href follows the route it is given', (tester) async {
      final notifier = ValueNotifier<int>(1);
      addTearDown(notifier.dispose);
      await boot(
        tester,
        ValueListenableBuilder<int>(
          valueListenable: notifier,
          builder: (context, id, _) => linkTile(ItemRoute(id), 'Item'),
        ),
      );
      expect(
        tester.widget<url.Link>(find.byType(url.Link)).uri!.path,
        '/items/1',
      );
      notifier.value = 5;
      await tester.pump();
      expect(
        tester.widget<url.Link>(find.byType(url.Link)).uri!.path,
        '/items/5',
      );
      await tester.tap(find.text('Item'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/items/5');
    });

    testWidgets('is a link with its URL for accessibility', (tester) async {
      final semantics = tester.ensureSemantics();
      await boot(tester, linkTile(const ItemRoute(2), 'Two'));
      final node = tester.getSemantics(find.text('Two'));
      final data = node.getSemanticsData();
      // Deprecated in newer Flutter (for isSemantics), which 3.32, the floor, does not have yet.
      // ignore: deprecated_member_use
      expect(node, containsSemantics(isLink: true));
      // Flutter 3.32 (the floor) drops the linkUrl when it merges the link's semantics.
      if (!onFlutterFloor) expect(data.linkUrl, Uri.parse('/items/2'));
      expect(data.label, 'Two');
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      semantics.dispose();
    });

    test('takes a route or a uri, not both nor neither', () {
      expect(
        () => RouteLink(
          to: const AboutRoute(),
          uri: Uri.parse('/about'),
          builder: (context, follow) => const SizedBox(),
        ),
        throwsAssertionError,
      );
      expect(
        () => RouteLink(builder: (context, follow) => const SizedBox()),
        throwsAssertionError,
      );
    });
  });

  group('uri: in debug', () {
    testWidgets('a location no route matches asserts, saying why', (
      tester,
    ) async {
      await boot(
        tester,
        RouteLink(
          uri: Uri.parse('/nope'),
          builder: (context, follow) => ListTile(onTap: follow),
        ),
      );
      final error = tester.takeException() as FlutterError;
      expect(error.toString(), contains('RouteLink(uri: /nope)'));
      expect(error.toString(), contains('no route of the GoRouter'));
    });

    testWidgets('a route of the router is fine', (tester) async {
      await boot(
        tester,
        RouteLink(
          uri: Uri.parse('/items/9'),
          builder: (context, follow) => ListTile(onTap: follow),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an injected matcher decides instead, bad segments included', (
      tester,
    ) async {
      await boot(
        tester,
        RouteLink(
          uri: Uri.parse('/items/abc'),
          builder: (context, follow) => ListTile(onTap: follow),
        ),
        scope: (child) => RouteLinkScope(
          match: (uri) => uri.path == '/items/2'
              ? UrlMatch(uri, const ItemRoute(2), const {}, [item(2)])
              : null,
          child: child,
        ),
      );
      final error = tester.takeException() as FlutterError;
      expect(error.toString(), contains('RouteLinkScope.match found no route'));
    });

    testWidgets('an external URL asserts: it is not a location of the app', (
      tester,
    ) async {
      await boot(
        tester,
        RouteLink(
          uri: Uri.parse('https://example.com/a'),
          builder: (context, follow) => ListTile(onTap: follow),
        ),
      );
      final error = tester.takeException() as FlutterError;
      expect(error.toString(), contains('is not a location in this app'));
    });
  });

  group('preload: intent', () {
    testWidgets('hover starts the data once, however often it comes back', (
      tester,
    ) async {
      final (_, container) = await boot(
        tester,
        linkTile(const ItemRoute(2), 'Two', preload: Preload.intent),
      );
      expect(loads, 0);
      final pointer = await mouse(tester);
      await pointer.moveTo(tester.getCenter(find.text('Two')));
      await tester.pump();
      expect(loads, 1);
      expect(container.exists(item(2)), isTrue);

      for (var i = 0; i < 3; i++) {
        await hover(tester, pointer, find.text('Two'));
      }
      await tester.pump();
      expect(loads, 1);
      // Moving away doesn't drop it: the click is about to follow.
      expect(container.exists(item(2)), isTrue);
    });

    testWidgets('the page finds the value warm when it is reached', (
      tester,
    ) async {
      final (_, container) = await boot(
        tester,
        linkTile(const ItemRoute(2), 'Two', preload: Preload.intent),
      );
      final pointer = await mouse(tester);
      await pointer.moveTo(tester.getCenter(find.text('Two')));
      await tester.pump();
      expect(container.read(item(2)).value, 'value 2');
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/items/2');
      expect(loads, 1);
    });

    testWidgets('a touch going down starts it, before the finger lifts', (
      tester,
    ) async {
      final (_, container) = await boot(
        tester,
        linkTile(const ItemRoute(2), 'Two', preload: Preload.intent),
      );
      final touch = await tester.startGesture(
        tester.getCenter(find.text('Two')),
      );
      expect(loads, 1);
      expect(container.exists(item(2)), isTrue);
      await touch.up();
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/items/2');
      expect(loads, 1);
    });

    testWidgets('focus starts it', (tester) async {
      await boot(
        tester,
        RouteLink(
          to: const ItemRoute(2),
          preload: Preload.intent,
          builder: (context, follow) =>
              TextButton(onPressed: follow, child: const Text('Two')),
        ),
      );
      expect(loads, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(loads, 1);
    });

    testWidgets('nothing loads without intent', (tester) async {
      await boot(
        tester,
        linkTile(const ItemRoute(2), 'Two', preload: Preload.intent),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(loads, 0);
    });

    testWidgets('disposing the link closes the handle', (tester) async {
      final (router, container) = await boot(
        tester,
        linkTile(const ItemRoute(2), 'Two', preload: Preload.intent),
      );
      final pointer = await mouse(tester);
      await pointer.moveTo(tester.getCenter(find.text('Two')));
      await tester.pump();
      expect(container.exists(item(2)), isTrue);

      // go: the page with the link is gone.
      router.go('/about');
      await tester.pumpAndSettle();
      expect(find.text('Two'), findsNothing);
      expect(container.exists(item(2)), isFalse);
    });

    testWidgets('a failed preload is not kept, and the next hover retries', (
      tester,
    ) async {
      final (_, container) = await boot(
        tester,
        linkTile(const ItemRoute(-1), 'Bad', preload: Preload.intent),
      );
      final pointer = await mouse(tester);
      await pointer.moveTo(tester.getCenter(find.text('Bad')));
      await tester.pump();
      await tester.pump();
      expect(loads, 1);
      expect(container.exists(item(-1)), isFalse);

      await hover(tester, pointer, find.text('Bad'));
      await tester.pump();
      expect(loads, 2);
    });

    testWidgets('a route without data preloads nothing, harmlessly', (
      tester,
    ) async {
      await boot(
        tester,
        linkTile(const AboutRoute(), 'About', preload: Preload.intent),
      );
      final pointer = await mouse(tester);
      await pointer.moveTo(tester.getCenter(find.text('About')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        const AboutRoute()
            .preload(tester.element(find.byType(RouteLink)) as WidgetRef)
            .isClosed,
        isTrue,
      );
    });

    testWidgets('preloading runs no guard and goes nowhere', (tester) async {
      await boot(
        tester,
        linkTile(const ItemRoute(2), 'Two', preload: Preload.intent),
      );
      final before = redirects;
      final pointer = await mouse(tester);
      await pointer.moveTo(tester.getCenter(find.text('Two')));
      await tester.pump();
      expect(loads, 1);
      expect(redirects, before);
      expect(currentLocation(tester), '/');
    });

    testWidgets('a changed route drops what was preloaded for the old one', (
      tester,
    ) async {
      final notifier = ValueNotifier<int>(1);
      addTearDown(notifier.dispose);
      final (_, container) = await boot(
        tester,
        ValueListenableBuilder<int>(
          valueListenable: notifier,
          builder: (context, id, _) =>
              linkTile(ItemRoute(id), 'Item', preload: Preload.intent),
        ),
      );
      final pointer = await mouse(tester);
      await pointer.moveTo(tester.getCenter(find.text('Item')));
      await tester.pump();
      expect(container.exists(item(1)), isTrue);
      notifier.value = 2;
      await tester.pump();
      await tester.pump();
      expect(container.exists(item(1)), isFalse);
      expect(container.exists(item(2)), isFalse);
      await hover(tester, pointer, find.text('Item'));
      await tester.pump();
      expect(container.exists(item(2)), isTrue);
    });
  });

  group('preload: visible', () {
    Widget list({Preload preload = Preload.visible}) => ListView.builder(
      itemExtent: 100,
      itemCount: 40,
      itemBuilder: (context, i) =>
          linkTile(ItemRoute(i), 'Item $i', preload: preload),
    );

    testWidgets('what is on screen loads, and only that', (tester) async {
      final (_, container) = await boot(tester, list());
      // 600 high: items 0 to 5.
      for (var i = 0; i < 6; i++) {
        expect(container.exists(item(i)), isTrue, reason: 'item $i');
      }
      expect(container.exists(item(6)), isFalse);
      expect(loads, 6);
    });

    testWidgets('scrolling releases what left and loads what came', (
      tester,
    ) async {
      final (_, container) = await boot(tester, list());
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pump();
      await tester.pump();
      expect(container.exists(item(0)), isFalse);
      expect(container.exists(item(20)), isTrue);
      expect(container.exists(item(25)), isTrue);
      // Back: it loads again, once per visit.
      final before = loads;
      await tester.drag(find.byType(ListView), const Offset(0, 2000));
      await tester.pump();
      await tester.pump();
      expect(container.exists(item(0)), isTrue);
      expect(loads, greaterThan(before));
    });

    testWidgets('rebuilds and scroll ticks do not load twice', (tester) async {
      await boot(tester, list());
      expect(loads, 6);
      final gesture = await tester.startGesture(const Offset(400, 300));
      for (var i = 0; i < 5; i++) {
        await gesture.moveBy(const Offset(0, -10));
        await tester.pump();
      }
      await gesture.moveBy(const Offset(0, 50));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      // Items 0 to 5 stayed on screen throughout; at most item 6 came in.
      expect(loads, lessThanOrEqualTo(7));
    });

    testWidgets('a link under another route is released, and back again', (
      tester,
    ) async {
      final (router, container) = await boot(
        tester,
        linkTile(const ItemRoute(2), 'Two', preload: Preload.visible),
      );
      expect(container.exists(item(2)), isTrue);
      unawaited(router.push<Object?>('/about'));
      await tester.pumpAndSettle();
      expect(container.exists(item(2)), isFalse);
      router.pop();
      await tester.pumpAndSettle();
      expect(container.exists(item(2)), isTrue);
    });

    testWidgets('a failed load is not tried again while it stays on screen', (
      tester,
    ) async {
      await boot(
        tester,
        ListView(
          children: [
            linkTile(const ItemRoute(-1), 'Bad', preload: Preload.visible),
            const SizedBox(height: 2000),
          ],
        ),
      );
      expect(loads, 1);
      for (var i = 0; i < 3; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -10));
        await tester.pump();
      }
      expect(find.text('Bad'), findsOneWidget);
      expect(loads, 1);
    });

    testWidgets('disposing closes every handle', (tester) async {
      final (router, container) = await boot(tester, list());
      expect(container.exists(item(0)), isTrue);
      router.go('/about');
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        expect(container.exists(item(i)), isFalse, reason: 'item $i');
      }
    });

    testWidgets('none preloads nothing, however long it is on screen', (
      tester,
    ) async {
      await boot(tester, list(preload: Preload.none));
      await tester.pump();
      expect(loads, 0);
    });
  });

  group('onPreload (since 0.9.0)', () {
    Widget tile(
      void Function(BuildContext context) onPreload, {
      Preload? preload = Preload.intent,
      TypedLocation to = const ItemRoute(2),
    }) => RouteLink(
      to: to,
      preload: preload,
      onPreload: onPreload,
      builder: (context, follow) =>
          ListTile(title: const Text('Two'), onTap: follow),
    );

    testWidgets(
      'runs once on hover, with the link\'s context, after the data started',
      (tester) async {
        final contexts = <BuildContext>[];
        final loadsSeen = <int>[];
        await boot(
          tester,
          tile((context) {
            contexts.add(context);
            loadsSeen.add(loads);
          }),
        );
        expect(contexts, isEmpty);
        final pointer = await mouse(tester);
        await hover(tester, pointer, find.text('Two'));
        expect(contexts, hasLength(1));
        expect(
          identical(contexts.single, tester.element(find.byType(RouteLink))),
          isTrue,
        );
        // After `route.preload(ref)` started the provider.
        expect(loadsSeen, [1]);
        // However often the pointer comes back: the preload is held, so it is not started again.
        for (var i = 0; i < 3; i++) {
          await hover(tester, pointer, find.text('Two'));
        }
        expect(contexts, hasLength(1));
      },
    );

    testWidgets('a touch going down, and focus, are intent too', (
      tester,
    ) async {
      var calls = 0;
      await boot(tester, tile((context) => calls++));
      final touch = await tester.startGesture(
        tester.getCenter(find.text('Two')),
      );
      await touch.cancel();
      await tester.pump();
      expect(calls, 1);
    });

    testWidgets('is not called without a preload', (tester) async {
      var calls = 0;
      await boot(tester, tile((context) => calls++, preload: Preload.none));
      final pointer = await mouse(tester);
      await hover(tester, pointer, find.text('Two'));
      expect(calls, 0);
      expect(loads, 0);
    });

    testWidgets('a RouteLinkScope\'s preload counts', (tester) async {
      var calls = 0;
      await boot(
        tester,
        tile((context) => calls++, preload: null),
        scope: (child) => RouteLinkScope(preload: Preload.intent, child: child),
      );
      final pointer = await mouse(tester);
      await hover(tester, pointer, find.text('Two'));
      expect(calls, 1);
    });

    testWidgets(
      'visible: runs when the link is on screen, and again when it comes back',
      (tester) async {
        var calls = 0;
        await boot(
          tester,
          ListView(
            children: [
              tile((context) => calls++, preload: Preload.visible),
              const SizedBox(height: 3000),
            ],
          ),
        );
        expect(calls, 1);
        await tester.drag(find.byType(ListView), const Offset(0, -2000));
        await tester.pump();
        await tester.pump();
        expect(calls, 1);
        await tester.drag(find.byType(ListView), const Offset(0, 2000));
        await tester.pump();
        await tester.pump();
        expect(calls, 2);
      },
    );

    testWidgets('runs again on the next intent after a failed preload', (
      tester,
    ) async {
      var calls = 0;
      await boot(tester, tile((context) => calls++, to: const ItemRoute(-1)));
      final pointer = await mouse(tester);
      await hover(tester, pointer, find.text('Two'));
      await tester.pump();
      await tester.pump();
      expect(calls, 1);
      await hover(tester, pointer, find.text('Two'));
      expect(calls, 2);
    });

    Widget uriLink(void Function(BuildContext context) onPreload) => RouteLink(
      uri: Uri.parse('/items/2'),
      preload: Preload.intent,
      onPreload: onPreload,
      builder: (context, follow) =>
          ListTile(title: const Text('Two'), onTap: follow),
    );

    testWidgets(
      'a uri: link with no match preloads nothing, so it does not call it',
      (tester) async {
        var calls = 0;
        await boot(tester, uriLink((context) => calls++));
        final pointer = await mouse(tester);
        await hover(tester, pointer, find.text('Two'));
        expect(calls, 0);
      },
    );

    testWidgets('a uri: link calls it when the scope\'s match found a route', (
      tester,
    ) async {
      var calls = 0;
      await boot(
        tester,
        uriLink((context) => calls++),
        scope: (child) => RouteLinkScope(
          match: (uri) =>
              UrlMatch(uri, const ItemRoute(2), const {}, [item(2)]),
          child: child,
        ),
      );
      final pointer = await mouse(tester);
      await hover(tester, pointer, find.text('Two'));
      expect(calls, 1);
    });

    testWidgets('what it throws is reported, and the preload goes on', (
      tester,
    ) async {
      final reported = <FlutterErrorDetails>[];
      final saved = FlutterError.onError;
      final (_, container) = await boot(
        tester,
        tile((context) => throw StateError('boom')),
      );
      FlutterError.onError = reported.add;
      try {
        final pointer = await mouse(tester);
        await hover(tester, pointer, find.text('Two'));
      } finally {
        FlutterError.onError = saved;
      }
      expect(reported, hasLength(1));
      expect(reported.single.exception, isA<StateError>());
      expect(reported.single.library, 'fespalier');
      expect(
        reported.single.context.toString(),
        'while running onPreload of a RouteLink to /items/2',
      );
      expect(container.exists(item(2)), isTrue);
    });
  });

  group('RouteLinkScope', () {
    testWidgets('sets the default, and a link can override it', (tester) async {
      final (_, container) = await boot(
        tester,
        Column(
          children: [
            linkTile(const ItemRoute(1), 'One'),
            linkTile(const ItemRoute(2), 'Two', preload: Preload.none),
          ],
        ),
        scope: (child) =>
            RouteLinkScope(preload: Preload.visible, child: child),
      );
      expect(container.exists(item(1)), isTrue);
      expect(container.exists(item(2)), isFalse);
    });

    testWidgets('changing the default releases what it started', (
      tester,
    ) async {
      final mode = ValueNotifier<Preload>(Preload.visible);
      addTearDown(mode.dispose);
      final (_, container) = await boot(
        tester,
        linkTile(const ItemRoute(1), 'One'),
        scope: (child) => ValueListenableBuilder<Preload>(
          valueListenable: mode,
          builder: (context, preload, _) =>
              RouteLinkScope(preload: preload, child: child),
        ),
      );
      expect(container.exists(item(1)), isTrue);
      mode.value = Preload.none;
      await tester.pump();
      await tester.pump();
      expect(container.exists(item(1)), isFalse);
      mode.value = Preload.visible;
      await tester.pump();
      await tester.pump();
      expect(container.exists(item(1)), isTrue);
    });

    testWidgets('match lets a uri: link preload', (tester) async {
      final (_, container) = await boot(
        tester,
        RouteLink(
          uri: Uri.parse('/items/2'),
          preload: Preload.visible,
          builder: (context, follow) => ListTile(onTap: follow),
        ),
        scope: (child) => RouteLinkScope(
          match: (uri) =>
              UrlMatch(uri, const ItemRoute(2), const {}, [item(2)]),
          child: child,
        ),
      );
      expect(container.exists(item(2)), isTrue);
    });

    testWidgets(
      'a uri: link preloads with the matched route: its data and its code',
      (tester) async {
        CodeRoute.preloads = 0;
        final (_, container) = await boot(
          tester,
          RouteLink(
            uri: Uri.parse('/code'),
            preload: Preload.intent,
            builder: (context, follow) =>
                ListTile(title: const Text('Code'), onTap: follow),
          ),
          scope: (child) => RouteLinkScope(
            match: (uri) =>
                UrlMatch(uri, const CodeRoute(), const {}, [item(7)]),
            child: child,
          ),
        );
        expect(CodeRoute.library.isLoaded, isFalse);
        final pointer = await mouse(tester);
        await hover(tester, pointer, find.text('Code'));
        expect(CodeRoute.preloads, 1);
        expect(container.exists(item(7)), isTrue);

        CodeRoute.completer.complete();
        await tester.pump();
        expect(CodeRoute.library.isLoaded, isTrue);
      },
    );

    testWidgets('without match a uri: link preloads nothing', (tester) async {
      final (_, container) = await boot(
        tester,
        RouteLink(
          uri: Uri.parse('/items/2'),
          preload: Preload.visible,
          builder: (context, follow) => ListTile(onTap: follow),
        ),
      );
      expect(container.exists(item(2)), isFalse);
      expect(loads, 0);
    });
  });
}
