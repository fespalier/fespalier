// Transitions.custom, Transitions.restorationIdOf and the PageMotion tag (since 0.19.0), and
// the two helpers that read them: motionOf and pumpTransition.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = ValueKey<String>('/things/:id');

Widget _scale(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondary,
  Widget child,
) => ScaleTransition(scale: animation, child: child);

class _Names extends NavigatorObserver {
  final pushed = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name);
  }
}

/// Every preset and a custom page, as children of `/` so that a dialog and a sheet have a page
/// to open over. Each page is built the way the generated file builds it, inside `namedPage`.
GoRouter _router(
  _Names names, {
  Duration duration = const Duration(seconds: 1),
}) {
  GoRoute entry(String path, Page<void> Function(LocalKey key) make) => GoRoute(
    path: path,
    pageBuilder: (context, state) =>
        namedPage('/$path', () => make(state.pageKey)),
  );
  return GoRouter(
    observers: [names],
    routes: [
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => namedPage(
          '/',
          () => Transitions.none(state.pageKey, const Text('home')),
        ),
        routes: [
          entry('fade', (k) => Transitions.fade(k, const Text('fade'))),
          entry('slide', (k) => Transitions.slide(k, const Text('slide'))),
          entry('none', (k) => Transitions.none(k, const Text('none'))),
          entry(
            'material',
            (k) => Transitions.material(k, const Text('material')),
          ),
          entry(
            'cupertino',
            (k) => Transitions.cupertino(k, const Text('cupertino')),
          ),
          entry('dialog', (k) => Transitions.dialog(k, const Text('dialog'))),
          entry('sheet', (k) => Transitions.sheet(k, const Text('sheet'))),
          entry(
            'full',
            (k) => Transitions.fullscreenDialog(k, const Text('full')),
          ),
          entry(
            'custom',
            (k) => Transitions.custom(
              k,
              const Text('custom'),
              transitionsBuilder: _scale,
              duration: duration,
              reverseDuration: duration * 2,
              heroes: const Heroes(onBackGesture: true),
            ),
          ),
        ],
      ),
    ],
  );
}

void main() {
  group('restorationIdOf', () {
    test('is the value of a ValueKey<String> and null for any other key', () {
      expect(Transitions.restorationIdOf(_key), '/things/:id');
      expect(Transitions.restorationIdOf(const ValueKey<int>(1)), isNull);
      expect(Transitions.restorationIdOf(UniqueKey()), isNull);
    });

    test('is the id every preset and custom give their page', () {
      final pages = <Page<void>>[
        Transitions.fade(_key, const Text('x')),
        Transitions.slide(_key, const Text('x')),
        Transitions.none(_key, const Text('x')),
        Transitions.material(_key, const Text('x')),
        Transitions.cupertino(_key, const Text('x')),
        Transitions.dialog(_key, const Text('x')),
        Transitions.sheet(_key, const Text('x')),
        Transitions.fullscreenDialog(_key, const Text('x')),
        Transitions.custom(_key, const Text('x'), transitionsBuilder: _scale),
      ];
      for (final page in pages) {
        expect(page.restorationId, Transitions.restorationIdOf(_key));
      }
      final unkeyed = Transitions.custom(
        const ValueKey<int>(1),
        const Text('x'),
        transitionsBuilder: _scale,
      );
      expect(unkeyed.restorationId, isNull);
    });
  });

  group('custom', () {
    test('is a CustomTransitionPage with the options it was given', () {
      const heroes = Heroes(onBackGesture: true);
      final child = const Text('x');
      final page =
          Transitions.custom(
                _key,
                child,
                transitionsBuilder: _scale,
                duration: const Duration(milliseconds: 120),
                heroes: heroes,
                opaque: false,
                barrierDismissible: true,
                barrierColor: Colors.black12,
                barrierLabel: 'close',
                fullscreenDialog: true,
              )
              as CustomTransitionPage<void>;
      expect(page.key, _key);
      expect(page.transitionDuration, const Duration(milliseconds: 120));
      expect(page.reverseTransitionDuration, const Duration(milliseconds: 120));
      expect(page.opaque, isFalse);
      expect(page.barrierDismissible, isTrue);
      expect(page.barrierColor, Colors.black12);
      expect(page.barrierLabel, 'close');
      expect(page.fullscreenDialog, isTrue);
      expect(page.transitionsBuilder, same(_scale));
      final wrapped = page.child as RouteHeroScope;
      expect(wrapped.heroes, heroes);
      expect(wrapped.child, same(child));
    });

    test(
      'keeps the child as it is without heroes, and has its own reverse',
      () {
        final child = const Text('x');
        final page =
            Transitions.custom(
                  _key,
                  child,
                  transitionsBuilder: _scale,
                  reverseDuration: const Duration(milliseconds: 50),
                )
                as CustomTransitionPage<void>;
        expect(page.child, same(child));
        expect(page.transitionDuration, const Duration(milliseconds: 300));
        expect(
          page.reverseTransitionDuration,
          const Duration(milliseconds: 50),
        );
      },
    );

    test(
      'is named by namedPage like the presets, and by nothing outside it',
      () {
        Page<void> make() => Transitions.custom(
          _key,
          const Text('x'),
          transitionsBuilder: _scale,
        );
        expect(make().name, isNull);
        expect(namedPage('/things/:id', make).name, '/things/:id');
        expect(
          namedPage('/things/:id', make).name,
          namedPage(
            '/things/:id',
            () => Transitions.fade(_key, const Text('x')),
          ).name,
        );
      },
    );

    testWidgets('is named, restored and animated through a real router', (
      tester,
    ) async {
      final names = _Names();
      final router = _router(names);
      await pumpRouter(tester, router);
      router.go('/custom');
      await pumpTransition(tester);
      expect(names.pushed.last, '/custom');
      final context = tester.element(find.text('custom'));
      final route = ModalRoute.of(context)!;
      expect((route.settings as Page<void>).restorationId, isNotNull);
      expect(find.byType(ScaleTransition), findsWidgets);
      expect(
        tester.widget<RouteHeroScope>(find.byType(RouteHeroScope)).heroes,
        const Heroes(onBackGesture: true),
      );
    });
  });

  group('PageMotion', () {
    final cases = <String, PageMotion>{
      'fade': PageMotion.fade,
      'slide': PageMotion.slide,
      'none': PageMotion.none,
      'material': PageMotion.material,
      'cupertino': PageMotion.cupertino,
      'dialog': PageMotion.dialog,
      'sheet': PageMotion.sheet,
      'full': PageMotion.fullscreenDialog,
      'custom': PageMotion.custom,
    };

    test('every preset tags its page, a page of the app has none', () {
      const text = Text('x');
      expect(PageMotion.of(Transitions.fade(_key, text)), PageMotion.fade);
      expect(PageMotion.of(Transitions.slide(_key, text)), PageMotion.slide);
      expect(PageMotion.of(Transitions.none(_key, text)), PageMotion.none);
      expect(
        PageMotion.of(Transitions.material(_key, text)),
        PageMotion.material,
      );
      expect(
        PageMotion.of(Transitions.cupertino(_key, text)),
        PageMotion.cupertino,
      );
      expect(PageMotion.of(Transitions.dialog(_key, text)), PageMotion.dialog);
      expect(PageMotion.of(Transitions.sheet(_key, text)), PageMotion.sheet);
      expect(
        PageMotion.of(Transitions.fullscreenDialog(_key, text)),
        PageMotion.fullscreenDialog,
      );
      expect(
        PageMotion.of(
          Transitions.custom(_key, text, transitionsBuilder: _scale),
        ),
        PageMotion.custom,
      );
      expect(
        PageMotion.of(
          Transitions.custom(
            _key,
            text,
            transitionsBuilder: _scale,
            motion: PageMotion.fade,
          ),
        ),
        PageMotion.fade,
      );
      expect(PageMotion.of(const MaterialPage<void>(child: text)), isNull);
    });

    for (final MapEntry(:key, :value) in cases.entries) {
      testWidgets('motionOf reads $value from the top route of /$key', (
        tester,
      ) async {
        final router = _router(_Names());
        await pumpRouter(tester, router);
        expect(motionOf(tester), PageMotion.none, reason: 'the home page');
        router.go('/$key');
        await tester.pumpAndSettle();
        expect(motionOf(tester), value);
      });
    }

    testWidgets('motionOf is null for a page Transitions did not build', (
      tester,
    ) async {
      await pumpRouter(
        tester,
        GoRouter(
          routes: [
            GoRoute(
              path: '/',
              pageBuilder: (context, state) => MaterialPage<void>(
                key: state.pageKey,
                child: const Text('own'),
              ),
            ),
          ],
        ),
      );
      expect(motionOf(tester), isNull);
    });
  });

  group('of', () {
    testWidgets('a finder that matches nothing or several is an error', (
      tester,
    ) async {
      await pumpRouter(tester, _router(_Names()));
      expect(
        () => motionOf(tester, of: find.text('nope')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('found 0'),
          ),
        ),
      );
      expect(
        () => motionOf(tester, of: find.byType(Directionality)),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('pumpTransition', () {
    testWidgets('inside a layout it asks for of:, which finds the page', (
      tester,
    ) async {
      final router = GoRouter(
        routes: [
          ShellRoute(
            pageBuilder: (context, state, child) =>
                Transitions.fade(state.pageKey, child),
            routes: [
              for (final name in ['a', 'b'])
                GoRoute(
                  path: '/$name',
                  pageBuilder: (context, state) => Transitions.custom(
                    state.pageKey,
                    Text(name),
                    transitionsBuilder: _scale,
                    duration: const Duration(seconds: 1),
                  ),
                ),
            ],
          ),
        ],
        initialLocation: '/a',
      );
      await pumpRouter(tester, router);
      router.go('/b');
      await pumpTransition(tester, of: find.text('b'));
      expect(motionOf(tester, of: find.text('b')), PageMotion.custom);
      router.go('/a');
      Object? error;
      try {
        await pumpTransition(tester);
      } on AssertionError catch (e) {
        error = e;
      }
      expect(error.toString(), contains('pass `of:`'));
    });

    double progress(WidgetTester tester) =>
        ModalRoute.of(tester.element(find.text('custom')))!.animation!.value;

    testWidgets('stops a fraction in, leaving the route animating', (
      tester,
    ) async {
      final router = _router(_Names());
      await pumpRouter(tester, router);
      router.go('/custom');
      await pumpTransition(tester, at: 0.5);
      final route = ModalRoute.of(tester.element(find.text('custom')))!;
      expect(route.animation!.status, AnimationStatus.forward);
      // easeOut-free: the page's animation is linear, so half the duration is half the value.
      expect(progress(tester), closeTo(0.5, 0.01));
      expect(tester.hasRunningAnimations, isTrue);
    });

    testWidgets('ends the transition at the end of its duration', (
      tester,
    ) async {
      final router = _router(_Names());
      await pumpRouter(tester, router);
      router.go('/custom');
      await pumpTransition(tester);
      final route = ModalRoute.of(tester.element(find.text('custom')))!;
      expect(route.animation!.status, AnimationStatus.completed);
      expect(progress(tester), 1);
    });

    testWidgets('a start of 0 stays on the first frame', (tester) async {
      final router = _router(_Names());
      await pumpRouter(tester, router);
      router.go('/custom');
      await pumpTransition(tester, at: 0);
      expect(progress(tester), 0);
    });

    testWidgets('uses the reverse duration while the route pops', (
      tester,
    ) async {
      final router = _router(_Names());
      await pumpRouter(tester, router);
      router.go('/custom');
      await pumpTransition(tester);
      router.go('/');
      await pumpTransition(tester, at: 0.5, of: find.text('custom'));
      // The popped page is on its way out: half the reverse duration gone.
      final route = ModalRoute.of(tester.element(find.text('custom')))!;
      expect(route.animation!.status, AnimationStatus.reverse);
      expect(progress(tester), closeTo(0.5, 0.01));
    });
  });
}
