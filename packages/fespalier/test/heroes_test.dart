// Shared elements: `RouteHero` and the `heroes:` of `Transitions.*`. A flight is detected by
// giving each hero a shuttle that shows a keyed box: while the box is on screen, the hero is
// in flight. The routers are hand-built, the way the generated one is for a route with a
// transition.dart (`pageBuilder:` and `Transitions.*`).
import 'dart:async' show unawaited;

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/cupertino.dart' show CupertinoPage;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A route whose location is whatever the test says, for `heroTag`.
class _Loc extends TypedLocation {
  const _Loc(this.location);

  @override
  final String location;
}

ValueKey<String> shuttleKey(String name) => ValueKey('shuttle $name');

/// A hero tagged [tag] whose flight shows a box keyed for [name] (the tag by default).
Widget hero(Object tag, {String? name}) => RouteHero(
  tag: tag,
  shuttle: (flight, animation, direction, from, to) =>
      SizedBox(key: shuttleKey(name ?? '$tag'), width: 20, height: 20),
  child: const SizedBox(width: 40, height: 40),
);

/// A page that is a Material page route, as `Transitions.material` builds it.
Page<void> page(GoRouterState state, Widget child, {LocalKey? key}) =>
    Transitions.material(key ?? state.pageKey, child);

/// Pumps the frames that show a flight in progress.
Future<void> midFlight(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<GoRouter> boot(WidgetTester tester, GoRouter router) async {
  await pumpRouter(tester, router);
  return router;
}

void main() {
  group('RouteHeroTag and heroTag', () {
    test('equal by path and name', () {
      expect(
        const RouteHeroTag('/p/1', 'image'),
        const RouteHeroTag('/p/1', 'image'),
      );
      expect(
        const RouteHeroTag('/p/1', 'image').hashCode,
        const RouteHeroTag('/p/1', 'image').hashCode,
      );
      expect(
        const RouteHeroTag('/p/1', 'image'),
        isNot(const RouteHeroTag('/p/2', 'image')),
      );
      expect(
        const RouteHeroTag('/p/1', 'image'),
        isNot(const RouteHeroTag('/p/1', 'title')),
      );
    });

    test('toString', () {
      expect(
        const RouteHeroTag('/p/1', 'image').toString(),
        'RouteHeroTag(/p/1, image)',
      );
    });

    test('the tag leaves the query out, and keeps the mount prefix', () {
      expect(
        const _Loc('/shop/products?sort=name&page=2').heroTag('row'),
        const RouteHeroTag('/shop/products', 'row'),
      );
      expect(
        const _Loc('/shop/products').heroTag('row'),
        const _Loc('/shop/products?page=3').heroTag('row'),
      );
      expect(const _Loc('/').heroTag('a'), const RouteHeroTag('/', 'a'));
    });

    test('an enum value is a name', () {
      expect(
        const _Loc('/p/1').heroTag(HeroFlightPath.arc),
        const _Loc('/p/1').heroTag(HeroFlightPath.arc),
      );
      expect(
        const _Loc('/p/1').heroTag(HeroFlightPath.arc),
        isNot(const _Loc('/p/1').heroTag(HeroFlightPath.straight)),
      );
    });

    testWidgets('hero is a RouteHero with the route tag', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: const _Loc('/p/1?x=2').hero('image', child: const Text('pic')),
        ),
      );
      final h = tester.widget<RouteHero>(find.byType(RouteHero));
      expect(h.tag, const RouteHeroTag('/p/1', 'image'));
      expect(find.text('pic'), findsOneWidget);
      expect(tester.widget<Hero>(find.byType(Hero)).tag, h.tag);
    });
  });

  group('flights', () {
    // A list and a detail page in one shell: the same navigator, so the shell's
    // controller flies them on push and on pop.
    GoRouter shellRouter() => GoRouter(
      initialLocation: '/list',
      routes: [
        ShellRoute(
          builder: (context, state, child) => child,
          routes: [
            GoRoute(
              path: '/list',
              pageBuilder: (context, state) =>
                  page(state, Center(child: hero('avatar'))),
            ),
            GoRoute(
              path: '/detail',
              pageBuilder: (context, state) =>
                  page(state, Align(child: hero('avatar'))),
            ),
          ],
        ),
      ],
    );

    testWidgets('push and pop inside a shell fly', (tester) async {
      final router = await boot(tester, shellRouter());
      expect(find.byKey(shuttleKey('avatar')), findsNothing);

      unawaited(router.push<void>('/detail'));
      await midFlight(tester);
      expect(find.byKey(shuttleKey('avatar')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(shuttleKey('avatar')), findsNothing);
      expect(find.byType(Hero), findsOneWidget);

      router.pop();
      await midFlight(tester);
      expect(find.byKey(shuttleKey('avatar')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(shuttleKey('avatar')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a dialog gets no flight', (tester) async {
      final router = await boot(
        tester,
        GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              pageBuilder: (context, state) =>
                  page(state, Center(child: hero('avatar'))),
            ),
            GoRoute(
              path: '/dialog',
              pageBuilder: (context, state) => Transitions.dialog(
                state.pageKey,
                Center(child: hero('avatar')),
              ),
            ),
          ],
        ),
      );
      unawaited(router.push<void>('/dialog'));
      await midFlight(tester);
      expect(find.byKey(shuttleKey('avatar')), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(Hero), findsNWidgets(2));
      expect(find.byKey(shuttleKey('avatar')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    group('remount', () {
      // `remountPage`'s way: a page keyed by the whole location is a new route for each.
      Future<GoRouter> remounting(WidgetTester tester) => boot(
        tester,
        GoRouter(
          initialLocation: '/c/1',
          routes: [
            GoRoute(
              path: '/c/:id',
              pageBuilder: (context, state) => page(
                state,
                Column(
                  children: [
                    hero('constant'),
                    // The tag taken from the segment: it differs on the two pages.
                    hero('segment ${state.pathParameters['id']}', name: 'id'),
                  ],
                ),
                key: ValueKey(state.uri.toString()),
              ),
            ),
          ],
        ),
      );

      testWidgets('a constant tag flies and a segment tag does not', (
        tester,
      ) async {
        final router = await remounting(tester);
        router.go('/c/2');
        await midFlight(tester);
        expect(find.byKey(shuttleKey('constant')), findsOneWidget);
        // 'segment 1' is only on the old page, 'segment 2' only on the new one.
        expect(find.byKey(shuttleKey('id')), findsNothing);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    });

    group('tabs', () {
      GoRouter tabsRouter(Widget Function() make) {
        final root = GlobalKey<NavigatorState>();
        return GoRouter(
          navigatorKey: root,
          initialLocation: '/a',
          routes: [
            StatefulShellRoute.indexedStack(
              builder: (context, state, shell) => shell,
              branches: [
                StatefulShellBranch(
                  routes: [
                    GoRoute(
                      path: '/a',
                      pageBuilder: (context, state) =>
                          page(state, Center(child: make())),
                      routes: [
                        GoRoute(
                          path: 'r',
                          parentNavigatorKey: root,
                          pageBuilder: (context, state) =>
                              page(state, Align(child: make())),
                        ),
                      ],
                    ),
                  ],
                ),
                StatefulShellBranch(
                  routes: [
                    GoRoute(
                      path: '/b',
                      pageBuilder: (context, state) =>
                          page(state, Center(child: make())),
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
      }

      Future<GoRouter> visitBoth(WidgetTester tester, GoRouter router) async {
        await boot(tester, router);
        router.go('/b');
        await tester.pumpAndSettle();
        router.go('/a');
        await tester.pumpAndSettle();
        return router;
      }

      testWidgets(
        'two tabs show one tag, and a root route over them flies from the shown tab',
        (tester) async {
          final router = await visitBoth(
            tester,
            tabsRouter(() => hero('shared')),
          );

          router.go('/a/r');
          await midFlight(tester);
          expect(tester.takeException(), isNull);
          expect(find.byKey(shuttleKey('shared')), findsOneWidget);
          await tester.pumpAndSettle();
          expect(find.byKey(shuttleKey('shared')), findsNothing);

          router.pop();
          await midFlight(tester);
          expect(tester.takeException(), isNull);
          expect(find.byKey(shuttleKey('shared')), findsOneWidget);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('control: a plain Hero in two tabs is a duplicate tag', (
        tester,
      ) async {
        final router = await visitBoth(
          tester,
          tabsRouter(
            () => Hero(
              tag: 'shared',
              flightShuttleBuilder: (flight, animation, direction, from, to) =>
                  SizedBox(key: shuttleKey('shared')),
              child: const SizedBox(width: 40, height: 40),
            ),
          ),
        );

        router.go('/a/r');
        await midFlight(tester);
        expect(tester.takeException(), isA<FlutterError>());
        await tester.pumpAndSettle();
        tester.takeException();
      });
    });
  });

  group('heroes:', () {
    final pages = <String, Page<void> Function(Widget child, Heroes? heroes)>{
      'fade': (child, heroes) =>
          Transitions.fade(const ValueKey('p'), child, heroes: heroes),
      'slide': (child, heroes) =>
          Transitions.slide(const ValueKey('p'), child, heroes: heroes),
      'none': (child, heroes) =>
          Transitions.none(const ValueKey('p'), child, heroes: heroes),
      'material': (child, heroes) =>
          Transitions.material(const ValueKey('p'), child, heroes: heroes),
      'cupertino': (child, heroes) =>
          Transitions.cupertino(const ValueKey('p'), child, heroes: heroes),
      'fullscreenDialog': (child, heroes) => Transitions.fullscreenDialog(
        const ValueKey('p'),
        child,
        heroes: heroes,
      ),
    };

    Widget childOf(Page<void> page) => switch (page) {
      final MaterialPage<void> p => p.child,
      final CupertinoPage<void> p => p.child,
      final CustomTransitionPage<void> p => p.child,
      _ => throw StateError('unexpected ${page.runtimeType}'),
    };

    for (final MapEntry(:key, :value) in pages.entries) {
      test('$key wraps the child in a scope when given heroes', () {
        const heroes = Heroes(onBackGesture: true);
        final child = hero('x');
        final wrapped = childOf(value(child, heroes));
        expect(wrapped, isA<RouteHeroScope>());
        expect((wrapped as RouteHeroScope).heroes, heroes);
        expect(wrapped.child, same(child));
      });

      test('$key passes the child on as it is without heroes', () {
        final child = hero('x');
        expect(childOf(value(child, null)), same(child));
      });
    }

    Future<Hero> built(
      WidgetTester tester,
      Heroes? heroes, {
      bool? onBackGesture,
      HeroFlightPath? path,
    }) async {
      final child = RouteHero(
        tag: 't',
        onBackGesture: onBackGesture,
        path: path,
        child: const SizedBox(),
      );
      final page = Transitions.material(
        const ValueKey('p'),
        child,
        heroes: heroes,
      );
      await tester.pumpWidget(MaterialApp(home: childOf(page)));
      return tester.widget<Hero>(find.byType(Hero));
    }

    testWidgets('a RouteHero takes the scope as its defaults', (tester) async {
      final hero = await built(
        tester,
        const Heroes(onBackGesture: true, path: HeroFlightPath.arc),
      );
      expect(hero.transitionOnUserGestures, isTrue);
      final tween = hero.createRectTween!(
        Rect.zero,
        const Rect.fromLTWH(10, 10, 10, 10),
      );
      expect(tween, isA<MaterialRectArcTween>());
    });

    testWidgets('straight is a plain RectTween', (tester) async {
      final hero = await built(
        tester,
        const Heroes(path: HeroFlightPath.straight),
      );
      expect(hero.transitionOnUserGestures, isFalse);
      final tween = hero.createRectTween!(Rect.zero, Rect.zero);
      expect(tween.runtimeType, RectTween);
    });

    testWidgets("without a scope, Flutter's own defaults", (tester) async {
      final hero = await built(tester, null);
      expect(hero.transitionOnUserGestures, isFalse);
      expect(hero.createRectTween, isNull);
      expect(hero.flightShuttleBuilder, isNull);
    });

    testWidgets('platform leaves the controller to decide', (tester) async {
      final hero = await built(tester, const Heroes());
      expect(hero.createRectTween, isNull);
    });

    testWidgets('an argument of the RouteHero overrides the scope', (
      tester,
    ) async {
      final hero = await built(
        tester,
        const Heroes(onBackGesture: true, path: HeroFlightPath.arc),
        onBackGesture: false,
        path: HeroFlightPath.straight,
      );
      expect(hero.transitionOnUserGestures, isFalse);
      expect(
        hero.createRectTween!(Rect.zero, Rect.zero).runtimeType,
        RectTween,
      );
    });

    Widget shuttle(
      BuildContext flight,
      Animation<double> animation,
      HeroFlightDirection direction,
      BuildContext from,
      BuildContext to,
    ) => const SizedBox();

    testWidgets("the scope's shuttle is the hero's", (tester) async {
      final hero = await built(tester, Heroes(shuttle: shuttle));
      expect(hero.flightShuttleBuilder, same(shuttle));
    });

    test('Heroes compares by value, and the shuttle by identity', () {
      expect(const Heroes(), const Heroes());
      expect(const Heroes().hashCode, const Heroes().hashCode);
      expect(const Heroes(onBackGesture: true), isNot(const Heroes()));
      expect(Heroes(shuttle: shuttle), Heroes(shuttle: shuttle));
      expect(const Heroes(path: HeroFlightPath.arc), isNot(const Heroes()));
    });

    testWidgets('the nearest scope wins', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RouteHeroScope(
            heroes: const Heroes(onBackGesture: true),
            child: RouteHeroScope(heroes: const Heroes(), child: hero('x')),
          ),
        ),
      );
      expect(
        tester.widget<Hero>(find.byType(Hero)).transitionOnUserGestures,
        isFalse,
      );
    });
  });
}
