// Transitions.sharedAxis and Transitions.fadeThrough (since 0.19.0): the Material 3 motion
// maths over widgets alone, played through a real router.
import 'dart:async' show unawaited;

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// M3's emphasized easing, copied from the implementation so that a test fails if either moves.
const _decelerate = Cubic(0.05, 0.7, 0.1, 1.0);
const _accelerate = Cubic(0.3, 0.0, 0.8, 0.15);

/// A 100 x 100 box at the top left, named [name], so that any slide or scale moves or sizes it.
Widget _body(String name) => Align(
  alignment: Alignment.topLeft,
  child: SizedBox(key: Key(name), width: 100, height: 100, child: Text(name)),
);

/// `/` (a [home] page) with `/b` below it, which is [make]'s page; `/b/c` is [makeC]'s.
GoRouter _router(
  Page<void> Function(LocalKey) make, {
  Page<void> Function(LocalKey)? home,
  Page<void> Function(LocalKey)? makeC,
}) {
  return GoRouter(
    routes: [
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => namedPage(
          '/',
          () => (home ?? (k) => Transitions.none(k, _body('a')))(state.pageKey),
        ),
        routes: [
          GoRoute(
            path: 'b',
            pageBuilder: (context, state) =>
                namedPage('/b', () => make(state.pageKey)),
            routes: [
              GoRoute(
                path: 'c',
                pageBuilder: (context, state) => namedPage(
                  '/b/c',
                  () => (makeC ?? (k) => Transitions.none(k, _body('c')))(
                    state.pageKey,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

Page<void> Function(LocalKey) _shared([
  SharedAxis axis = SharedAxis.x,
  Color? fill,
]) =>
    (k) => Transitions.sharedAxis(k, _body('b'), axis: axis, fill: fill);

Page<void> _fadeThrough(LocalKey k) => Transitions.fadeThrough(k, _body('b'));

/// The product of every Opacity above the box named [name]: how visible it is.
double _opacity(WidgetTester tester, String name) => tester
    .widgetList<Opacity>(
      find.ancestor(of: find.byKey(Key(name)), matching: find.byType(Opacity)),
    )
    .fold(1.0, (a, o) => a * o.opacity);

Offset _topLeft(WidgetTester tester, String name) =>
    tester.getTopLeft(find.byKey(Key(name)));

double _width(WidgetTester tester, String name) =>
    (tester.getBottomRight(find.byKey(Key(name))) -
            tester.getTopLeft(find.byKey(Key(name))))
        .dx;

Future<GoRouter> _boot(
  WidgetTester tester,
  GoRouter router, {
  Widget Function(GoRouter)? app,
}) async {
  await pumpRouter(tester, router, app: app);
  return router;
}

/// Pushes `/b` and stops [at] of the way into the transition.
Future<void> _push(WidgetTester tester, GoRouter router, double at) async {
  unawaited(router.push<void>('/b'));
  await pumpTransition(tester, at: at);
}

void _reduced(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

double _in(double t) => ((t - 0.3) / 0.7).clamp(0.0, 1.0);

void main() {
  group('shared axis x', () {
    testWidgets(
      'the incoming page fades in from 30% and slides in from 30 dp',
      (tester) async {
        final router = await _boot(tester, _router(_shared()));
        final rest = _topLeft(tester, 'a');
        await _push(tester, router, 0);
        expect(_opacity(tester, 'b'), closeTo(0, 0.01));
        expect(_topLeft(tester, 'b').dx - rest.dx, closeTo(30, 0.5));
        expect(_topLeft(tester, 'b').dy, rest.dy);
        await tester.pumpAndSettle();
        // Replay to 35%.
        router.pop();
        await tester.pumpAndSettle();
        await _push(tester, router, 0.35);
        expect(_opacity(tester, 'b'), closeTo(_in(0.35), 0.03));
        expect(_opacity(tester, 'b'), lessThan(0.2));
        expect(
          _topLeft(tester, 'b').dx - rest.dx,
          closeTo(30 * (1 - _decelerate.transform(0.35)), 1),
        );
        await tester.pumpAndSettle();
        expect(_opacity(tester, 'b'), 1);
        expect(_topLeft(tester, 'b'), rest);
      },
    );

    testWidgets('at the end the page is at rest', (tester) async {
      final router = await _boot(tester, _router(_shared()));
      final rest = _topLeft(tester, 'a');
      await _push(tester, router, 1);
      expect(_opacity(tester, 'b'), 1);
      expect(_topLeft(tester, 'b'), rest);
    });

    testWidgets('on pop the leaving page slides out the other way', (
      tester,
    ) async {
      final router = await _boot(tester, _router(_shared()));
      await _push(tester, router, 1);
      await tester.pumpAndSettle();
      final rest = _topLeft(tester, 'b');
      router.pop();
      await tester.pump();
      await tester.pump(
        const Duration(milliseconds: 270),
      ); // 10% of the way out
      // Leaving: opacity falls over the first 35% of the way out, and it goes right (+30).
      expect(_topLeft(tester, 'b').dx - rest.dx, greaterThan(0));
      expect(_opacity(tester, 'b'), lessThan(1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('b')), findsNothing);
    });

    testWidgets('RTL mirrors the slide', (tester) async {
      final router = await _boot(
        tester,
        _router(_shared()),
        app: (router) => MaterialApp.router(
          routerConfig: router,
          builder: (context, child) =>
              Directionality(textDirection: TextDirection.rtl, child: child!),
        ),
      );
      await _push(tester, router, 0);
      // In RTL the Align's top left is still the left of the screen, and the page comes from -30.
      final rest = _topLeft(tester, 'a');
      expect(_topLeft(tester, 'b').dx - rest.dx, closeTo(-30, 0.5));
    });
  });

  group('shared axis y and z', () {
    testWidgets('y moves vertically', (tester) async {
      final router = await _boot(tester, _router(_shared(SharedAxis.y)));
      final rest = _topLeft(tester, 'a');
      await _push(tester, router, 0);
      expect(_topLeft(tester, 'b').dy - rest.dy, closeTo(30, 0.5));
      expect(_topLeft(tester, 'b').dx, rest.dx);
    });

    testWidgets('z scales the incoming page from 0.8 and does not move it', (
      tester,
    ) async {
      final router = await _boot(tester, _router(_shared(SharedAxis.z)));
      await _push(tester, router, 0);
      expect(_width(tester, 'b'), closeTo(80, 0.5));
      expect(_opacity(tester, 'b'), closeTo(0, 0.01));
      await tester.pumpAndSettle();
      expect(_width(tester, 'b'), 100);
    });

    testWidgets('z: the page below grows to 1.1 and the leaving page shrinks', (
      tester,
    ) async {
      final router = await _boot(
        tester,
        _router(
          _shared(SharedAxis.z),
          home: (k) =>
              Transitions.sharedAxis(k, _body('a'), axis: SharedAxis.z),
        ),
      );
      unawaited(router.push<void>('/b'));
      await pumpTransition(tester, of: find.byKey(const Key('b')), at: 0.6);
      expect(
        _width(tester, 'a'),
        closeTo(100 * (1 + 0.1 * _accelerate.transform(0.6)), 0.5),
      );
      await tester.pumpAndSettle();
      router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(_width(tester, 'b'), lessThan(100));
      expect(_width(tester, 'b'), greaterThanOrEqualTo(80));
      await tester.pumpAndSettle();
    });
  });

  group('fade through', () {
    testWidgets(
      'the incoming page is hidden until 35%, then fades and scales',
      (tester) async {
        final router = await _boot(tester, _router(_fadeThrough));
        await _push(tester, router, 0.3);
        expect(_opacity(tester, 'b'), closeTo(0, 0.001));
        await tester.pumpAndSettle();
        router.pop();
        await tester.pumpAndSettle();
        await _push(tester, router, 0.0);
        expect(_width(tester, 'b'), closeTo(92, 0.5));
        await tester.pumpAndSettle();
        router.pop();
        await tester.pumpAndSettle();
        await _push(tester, router, 0.7);
        final local = (0.7 - 0.35) / 0.65;
        expect(_opacity(tester, 'b'), closeTo(local, 0.03));
        expect(
          _width(tester, 'b'),
          closeTo(100 * (0.92 + 0.08 * _decelerate.transform(local)), 0.7),
        );
        await tester.pumpAndSettle();
        expect(_width(tester, 'b'), 100);
        expect(_opacity(tester, 'b'), 1);
      },
    );
  });

  group('the page below', () {
    testWidgets('a shared axis page over a shared axis page fades out over 35% '
        'and slides', (tester) async {
      final router = await _boot(
        tester,
        _router(_shared(), home: (k) => Transitions.sharedAxis(k, _body('a'))),
      );
      final rest = _topLeft(tester, 'a');
      unawaited(router.push<void>('/b'));
      await pumpTransition(tester, at: 0.1);
      // `a` is the covered page: 10% in, fading out and moving left (-30 * accelerate).
      expect(_opacity(tester, 'a'), closeTo(1 - 0.1 / 0.35, 0.05));
      expect(
        _topLeft(tester, 'a').dx - rest.dx,
        closeTo(-30 * _accelerate.transform(0.1), 0.7),
      );
      await tester.pump(const Duration(milliseconds: 150)); // 60%: gone
      expect(_opacity(tester, 'a'), 0);
      await tester.pumpAndSettle();
      // Coming back: `a` is uncovered and returns to rest.
      router.pop();
      await tester.pumpAndSettle();
      expect(_opacity(tester, 'a'), 1);
      expect(_topLeft(tester, 'a'), rest);
    });

    testWidgets('a shared axis page over a none page still enters correctly', (
      tester,
    ) async {
      final router = await _boot(tester, _router(_shared()));
      final rest = _topLeft(tester, 'a');
      await _push(tester, router, 0);
      expect(_opacity(tester, 'b'), closeTo(0, 0.01));
      expect(_topLeft(tester, 'b').dx - rest.dx, closeTo(30, 0.5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('b')), findsOneWidget);
    });

    testWidgets('a dialog or a sheet over it does not move the page', (
      tester,
    ) async {
      for (final make in <Page<void> Function(LocalKey)>[
        (k) => Transitions.dialog(k, const Text('over')),
        (k) => Transitions.sheet(k, const Text('over')),
      ]) {
        final router = await _boot(
          tester,
          _router(make, home: (k) => Transitions.sharedAxis(k, _body('a'))),
        );
        final rest = _topLeft(tester, 'a');
        unawaited(router.push<void>('/b'));
        await tester.pumpAndSettle();
        expect(_opacity(tester, 'a'), 1);
        expect(_topLeft(tester, 'a'), rest);
      }
    });

    testWidgets('a page keeps its state through the transition', (
      tester,
    ) async {
      final router = await _boot(
        tester,
        _router((k) => Transitions.sharedAxis(k, const _Counter())),
      );
      unawaited(router.push<void>('/b'));
      await pumpTransition(tester, at: 0.3);
      final state = tester.state<_CounterState>(find.byType(_Counter));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.state<_CounterState>(find.byType(_Counter)), same(state));
      await tester.pumpAndSettle();
      expect(tester.state<_CounterState>(find.byType(_Counter)), same(state));
    });
  });

  group('the fill', () {
    Finder filled(Color color) =>
        find.byWidgetPredicate((w) => w is ColoredBox && w.color == color);

    testWidgets('an explicit fill paints behind the page', (tester) async {
      const color = Color(0xFF123456);
      final router = await _boot(tester, _router(_shared(SharedAxis.x, color)));
      await _push(tester, router, 0.5);
      expect(
        find.descendant(
          of: find.byType(Opacity).first,
          matching: filled(color),
        ),
        findsWidgets,
      );
    });

    testWidgets('a MotionFill above the router gives the same', (tester) async {
      const color = Color(0xFF654321);
      final router = await _boot(
        tester,
        _router(_shared()),
        app: (router) => MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => MotionFill(color: color, child: child!),
        ),
      );
      await _push(tester, router, 0.5);
      expect(filled(color), findsWidgets);
      expect(
        MotionFill.maybeOf(tester.element(find.byKey(const Key('b')))),
        color,
      );
    });

    testWidgets('an explicit fill wins over the MotionFill', (tester) async {
      const above = Color(0xFF111111);
      const own = Color(0xFF222222);
      final router = await _boot(
        tester,
        _router(_shared(SharedAxis.x, own)),
        app: (router) => MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => MotionFill(color: above, child: child!),
        ),
      );
      await _push(tester, router, 0.5);
      expect(filled(own), findsWidgets);
      expect(filled(above), findsNothing);
    });

    testWidgets('neither gives a transparent page: no coloured box', (
      tester,
    ) async {
      final router = await _boot(tester, _router(_shared()));
      await _push(tester, router, 0.5);
      final boxes = find.ancestor(
        of: find.byKey(const Key('b')),
        matching: find.byType(ColoredBox),
      );
      // Only the ones the app's own widgets (the Navigator's, the Material's) put there; none
      // is between the page and the transition's Opacity.
      final opacity = find.ancestor(
        of: find.byKey(const Key('b')),
        matching: find.byType(Opacity),
      );
      expect(opacity, findsWidgets);
      expect(find.descendant(of: opacity.last, matching: boxes), findsNothing);
      expect(
        MotionFill.maybeOf(tester.element(find.byKey(const Key('b')))),
        isNull,
      );
    });
  });

  group('reduced motion', () {
    testWidgets('shared axis is a cross-fade: no offset, no scale', (
      tester,
    ) async {
      _reduced(tester);
      for (final axis in SharedAxis.values) {
        final router = await _boot(tester, _router(_shared(axis)));
        final rest = _topLeft(tester, 'a');
        unawaited(router.push<void>('/b'));
        await pumpTransition(tester, at: 0.02);
        expect(_topLeft(tester, 'b'), rest, reason: '$axis');
        expect(_width(tester, 'b'), 100, reason: '$axis');
        expect(_opacity(tester, 'b'), allOf(greaterThan(0), lessThan(1)));
        await tester.pumpAndSettle();
        expect(_opacity(tester, 'b'), 1);
      }
    });

    testWidgets('fade through is a cross-fade', (tester) async {
      _reduced(tester);
      final router = await _boot(tester, _router(_fadeThrough));
      unawaited(router.push<void>('/b'));
      await pumpTransition(tester, at: 0.02);
      expect(_width(tester, 'b'), 100);
      expect(_opacity(tester, 'b'), allOf(greaterThan(0), lessThan(1)));
      await tester.pumpAndSettle();
    });

    testWidgets('the page below keeps still', (tester) async {
      _reduced(tester);
      final router = await _boot(
        tester,
        _router(_shared(), home: (k) => Transitions.sharedAxis(k, _body('a'))),
      );
      final rest = _topLeft(tester, 'a');
      unawaited(router.push<void>('/b'));
      await pumpTransition(tester, at: 0.02);
      expect(_topLeft(tester, 'a'), rest);
      expect(_opacity(tester, 'a'), 1);
      await tester.pumpAndSettle();
    });
  });

  group('the tag', () {
    testWidgets('motionOf answers sharedAxis and fadeThrough', (tester) async {
      var router = await _boot(tester, _router(_shared()));
      unawaited(router.push<void>('/b'));
      await pumpTransition(tester, at: 1);
      expect(motionOf(tester), PageMotion.sharedAxis);

      router = await _boot(tester, _router(_fadeThrough));
      unawaited(router.push<void>('/b'));
      await pumpTransition(tester, at: 1);
      expect(motionOf(tester), PageMotion.fadeThrough);
    });

    test('Transitions.custom accepts the motion', () {
      final page = Transitions.custom(
        const ValueKey<String>('k'),
        const SizedBox(),
        motion: PageMotion.sharedAxis,
        transitionsBuilder: (context, animation, secondary, child) => child,
      );
      expect(PageMotion.of(page), PageMotion.sharedAxis);
    });

    test('the presets carry the page name and the restoration id', () {
      const key = ValueKey<String>('/b');
      final page = Transitions.sharedAxis(key, const SizedBox());
      expect(page.restorationId, '/b');
      expect(page, isA<Page<void>>());
    });
  });
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  @override
  Widget build(BuildContext context) => const Text('counter');
}
