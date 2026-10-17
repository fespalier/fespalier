// Reduced motion (since 0.19.0): every Transitions page and RouteHero honour
// MediaQuery.disableAnimations, read from the route's own context. Each case runs with the flag
// on and with it off, where the behaviour is what it always was.
import 'dart:async' show unawaited;

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoPage, CupertinoPageTransition;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _shuttle = ValueKey<String>('shuttle');

/// Page text sits at the top left, so that any slide, scale or parallax moves it.
Widget _body(String name) =>
    Align(alignment: Alignment.topLeft, child: Text(name));

/// `/` and, below it, one route per preset. Each page is built inside `namedPage`, as the
/// generated file does.
GoRouter _router() {
  GoRoute entry(String path, Page<void> Function(LocalKey key) make) => GoRoute(
    path: path,
    pageBuilder: (context, state) =>
        namedPage('/$path', () => make(state.pageKey)),
  );
  return GoRouter(
    routes: [
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => namedPage(
          '/',
          () => Transitions.none(state.pageKey, _body('home')),
        ),
        routes: [
          entry('fade', (k) => Transitions.fade(k, _body('fade'))),
          entry('slide', (k) => Transitions.slide(k, _body('slide'))),
          entry('none', (k) => Transitions.none(k, _body('none'))),
          entry('material', (k) => Transitions.material(k, _body('material'))),
          entry(
            'cupertino',
            (k) => Transitions.cupertino(k, _body('cupertino')),
          ),
          entry('full', (k) => Transitions.fullscreenDialog(k, _body('full'))),
          entry('dialog', (k) => Transitions.dialog(k, const Text('dialog'))),
          entry('sheet', (k) => Transitions.sheet(k, const Text('sheet'))),
          entry(
            'custom',
            (k) => Transitions.custom(
              k,
              _body('custom'),
              transitionsBuilder: (context, animation, secondary, child) =>
                  SlideTransition(
                    position: Tween(
                      begin: const Offset(1, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
            ),
          ),
        ],
      ),
    ],
  );
}

/// Flutter itself runs a route's controller at a twentieth of its duration while animations
/// are disabled, so the middle of a transition is much earlier than half of its duration.
bool _flagOn = false;

double get _middle => _flagOn ? 0.02 : 0.5;

void _reduced(WidgetTester tester, bool on) {
  _flagOn = on;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: on);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

/// Boots [_router] at `/` and goes to [path], leaving the transition at [at].
Future<GoRouter> _open(WidgetTester tester, String path, {double? at}) async {
  final router = _router();
  await pumpRouter(tester, router);
  unawaited(router.push<void>('/$path'));
  await pumpTransition(tester, at: at ?? _middle);
  return router;
}

Iterable<T> _above<T extends Widget>(WidgetTester tester, String text) =>
    tester.widgetList<T>(
      find.ancestor(of: find.text(text), matching: find.byType(T)),
    );

double _minOpacity(WidgetTester tester, String text) => _above<FadeTransition>(
  tester,
  text,
).map((f) => f.opacity.value).fold(1.0, (a, b) => a < b ? a : b);

bool _anyOffset(WidgetTester tester, String text) => _above<SlideTransition>(
  tester,
  text,
).any((s) => s.position.value != Offset.zero);

/// Where the page's text is mid-flight against where it rests, as a distance.
Future<double> _travel(WidgetTester tester, String path, String text) async {
  await _open(tester, path);
  final mid = tester.getTopLeft(find.text(text));
  await tester.pumpAndSettle();
  return (mid - tester.getTopLeft(find.text(text))).distance;
}

void main() {
  for (final reduced in [true, false]) {
    group(reduced ? 'reduced motion on' : 'reduced motion off', () {
      testWidgets('slide: a cross-fade when reduced, a slide otherwise', (
        tester,
      ) async {
        _reduced(tester, reduced);
        await _open(tester, 'slide');
        expect(_anyOffset(tester, 'slide'), !reduced);
        expect(_minOpacity(tester, 'slide'), reduced ? lessThan(1) : 1);
        await tester.pumpAndSettle();
        expect(_minOpacity(tester, 'slide'), 1);
        expect(tester.takeException(), isNull);
      });

      testWidgets('slide: pops back with the same motion', (tester) async {
        _reduced(tester, reduced);
        final router = await _open(tester, 'slide');
        await tester.pumpAndSettle();
        router.pop();
        await tester.pump();
        await tester.pump(Duration(milliseconds: _flagOn ? 4 : 150));
        expect(_anyOffset(tester, 'slide'), !reduced);
        expect(_minOpacity(tester, 'slide'), reduced ? lessThan(1) : 1);
        await tester.pumpAndSettle();
        expect(find.text('slide'), findsNothing);
      });

      testWidgets('fade and none do not change', (tester) async {
        _reduced(tester, reduced);
        await _open(tester, 'fade');
        expect(_minOpacity(tester, 'fade'), lessThan(1));
        expect(_anyOffset(tester, 'fade'), isFalse);
        await tester.pumpAndSettle();
      });

      testWidgets('none appears at once', (tester) async {
        _reduced(tester, reduced);
        await _open(tester, 'none', at: 0);
        expect(find.text('none'), findsOneWidget);
        expect(_minOpacity(tester, 'none'), 1);
      });

      testWidgets('custom keeps its own builder', (tester) async {
        _reduced(tester, reduced);
        await _open(tester, 'custom');
        expect(_anyOffset(tester, 'custom'), isTrue);
      });

      testWidgets('the PageMotion tag is the preset\'s own', (tester) async {
        _reduced(tester, reduced);
        await _open(tester, 'slide', at: 1);
        expect(motionOf(tester), PageMotion.slide);
        final page = Transitions.material(
          const ValueKey<String>('a'),
          const SizedBox(),
        );
        expect(PageMotion.of(page), PageMotion.material);
      });

      testWidgets('material and fullscreenDialog stay Material pages', (
        tester,
      ) async {
        _reduced(tester, reduced);
        final key = const ValueKey<String>('k');
        expect(
          Transitions.material(key, const SizedBox()),
          isA<MaterialPage<void>>(),
        );
        final full = Transitions.fullscreenDialog(key, const SizedBox());
        expect(full, isA<MaterialPage<void>>());
        expect((full as MaterialPage<void>).fullscreenDialog, isTrue);
        expect(
          Transitions.cupertino(key, const SizedBox()),
          isA<CupertinoPage<void>>(),
        );
      });

      for (final path in ['material', 'full']) {
        testWidgets(
          '$path: no position change when reduced, a slide on iOS otherwise',
          (tester) async {
            _reduced(tester, reduced);
            final travel = await _travel(tester, path, path);
            if (reduced) {
              expect(travel, 0);
            } else {
              expect(travel, greaterThan(0));
            }
          },
          variant: TargetPlatformVariant.only(TargetPlatform.iOS),
        );

        testWidgets('$path: fades in place when reduced (Android)', (
          tester,
        ) async {
          _reduced(tester, reduced);
          final travel = await _travel(tester, path, path);
          if (reduced) expect(travel, 0);
          expect(tester.takeException(), isNull);
        }, variant: TargetPlatformVariant.only(TargetPlatform.android));
      }

      testWidgets(
        'cupertino: no position change when reduced, a slide otherwise',
        (tester) async {
          _reduced(tester, reduced);
          await _open(tester, 'cupertino');
          final mid = tester.getTopLeft(find.text('cupertino'));
          expect(_minOpacity(tester, 'cupertino'), reduced ? lessThan(1) : 1);
          await tester.pumpAndSettle();
          final end = tester.getTopLeft(find.text('cupertino'));
          if (reduced) {
            expect(mid, end);
            expect(find.byType(CupertinoPageTransition), findsOneWidget);
          } else {
            expect(mid, isNot(end));
          }
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );

      testWidgets('cupertino: the page below stays put under it when reduced', (
        tester,
      ) async {
        _reduced(tester, reduced);
        await _open(tester, 'cupertino');
        final mid = tester.getTopLeft(find.text('home', skipOffstage: false));
        await tester.pumpAndSettle();
        final end = tester.getTopLeft(find.text('home', skipOffstage: false));
        if (reduced) expect(mid, end);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

      testWidgets('cupertino: the back swipe from the left edge still pops', (
        tester,
      ) async {
        _reduced(tester, reduced);
        await _open(tester, 'cupertino', at: 1);
        await tester.pumpAndSettle();
        expect(find.text('cupertino'), findsOneWidget);
        await tester.dragFrom(const Offset(4, 300), const Offset(500, 0));
        await tester.pumpAndSettle();
        expect(find.text('cupertino'), findsNothing);
        expect(find.text('home'), findsOneWidget);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

      testWidgets('material: the page pops with the system back', (
        tester,
      ) async {
        _reduced(tester, reduced);
        final router = await _open(tester, 'material', at: 1);
        await tester.pumpAndSettle();
        router.pop();
        await tester.pumpAndSettle();
        expect(find.text('material'), findsNothing);
        expect(find.text('home'), findsOneWidget);
      });

      for (final path in ['dialog', 'sheet']) {
        testWidgets(
          '$path: ${reduced ? 'fully shown after one pump' : 'animates'}',
          (tester) async {
            _reduced(tester, reduced);
            final router = _router();
            await pumpRouter(tester, router);
            unawaited(router.push<void>('/$path'));
            await tester.pump();
            await tester.pump();
            final route = ModalRoute.of(tester.element(find.text(path)))!;
            if (reduced) {
              expect(route.animation!.value, 1);
            } else {
              expect(route.animation!.value, lessThan(1));
            }
            await tester.pumpAndSettle();
            expect(find.text(path), findsOneWidget);
            expect(route.animation!.value, 1);
          },
        );
      }

      testWidgets('RouteHero flies only when motion is not reduced', (
        tester,
      ) async {
        _reduced(tester, reduced);
        Widget hero() => RouteHero(
          tag: 'avatar',
          shuttle: (flight, animation, direction, from, to) =>
              const SizedBox(key: _shuttle, width: 20, height: 20),
          child: const SizedBox(width: 40, height: 40),
        );
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              pageBuilder: (context, state) => Transitions.material(
                state.pageKey,
                Align(alignment: Alignment.topLeft, child: hero()),
              ),
              routes: [
                GoRoute(
                  path: 'detail',
                  pageBuilder: (context, state) => Transitions.material(
                    state.pageKey,
                    Align(alignment: Alignment.bottomRight, child: hero()),
                  ),
                ),
              ],
            ),
          ],
        );
        await pumpRouter(tester, router);
        unawaited(router.push<void>('/detail'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(_shuttle), reduced ? findsNothing : findsOneWidget);
        await tester.pumpAndSettle();
        expect(find.byKey(_shuttle), findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('a caller\'s animationStyle wins over reduced motion', (
    tester,
  ) async {
    _reduced(tester, true);
    const style = AnimationStyle(duration: Duration(seconds: 1));
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (context, state) =>
              Transitions.none(state.pageKey, const Text('home')),
          routes: [
            GoRoute(
              path: 'sheet',
              pageBuilder: (context, state) => Transitions.sheet(
                state.pageKey,
                const Text('sheet'),
                animationStyle: style,
              ),
            ),
          ],
        ),
      ],
    );
    await pumpRouter(tester, router);
    unawaited(router.push<void>('/sheet'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    final route = ModalRoute.of(tester.element(find.text('sheet')))!;
    expect(route.animation!.value, lessThan(1));
    await tester.pumpAndSettle();
  });
}
