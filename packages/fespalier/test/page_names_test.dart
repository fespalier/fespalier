// Page names (since 0.9.0): the generated router wraps each page builder it writes in
// `namedPage('<pattern>', () => ...)`, and `Transitions.*`, `layoutPage` and `remountPage` name
// their page with it, so a `NavigatorObserver` (Sentry's, Firebase Analytics', PostHog's) sees
// `/products/:id`. The routers here are what the generator writes.
import 'dart:async' show unawaited;

import 'package:fespalier/fespalier.dart';
import 'package:flutter/cupertino.dart' show CupertinoPage;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Collects the name of every route that is pushed to it.
class Names extends NavigatorObserver {
  final pushed = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name);
  }
}

const _key = ValueKey<String>('k');

Page<void> _built(Page<void> Function() make) => make();

GoRouter router(Names names) => GoRouter(
  observers: [names],
  routes: [
    ShellRoute(
      pageBuilder: (context, state, child) =>
          namedPage('/', () => layoutPage(context, state, 'layout:/', child)),
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (context, state) => namedPage(
            '/',
            () => Transitions.none(state.pageKey, const Text('home')),
          ),
          routes: [
            GoRoute(
              path: 'products/:id',
              pageBuilder: (context, state) => namedPage(
                '/products/:id',
                () => Transitions.fade(
                  state.pageKey,
                  Text('product ${state.pathParameters['id']}'),
                ),
              ),
            ),
            GoRoute(
              path: 'dialog',
              pageBuilder: (context, state) => namedPage(
                '/dialog',
                () => Transitions.dialog(state.pageKey, const Text('dialog')),
              ),
            ),
            GoRoute(
              path: 'sheet',
              pageBuilder: (context, state) => namedPage(
                '/sheet',
                () => Transitions.sheet(state.pageKey, const Text('sheet')),
              ),
            ),
            GoRoute(
              path: 'items/:id',
              pageBuilder: (context, state) => namedPage(
                '/items/:id',
                () => remountPage(
                  context,
                  state,
                  remountKey(state, Remount.onSegments, const ['id']),
                  Text('item ${state.pathParameters['id']}'),
                ),
              ),
            ),
            GoRoute(
              path: 'bare',
              builder: (context, state) => const Text('bare'),
            ),
          ],
        ),
      ],
    ),
  ],
);

void main() {
  group('namedPage', () {
    test('names the pages built inside it, and only while it builds', () {
      expect(Transitions.pageName, isNull);
      final page = namedPage('/a/:id', () {
        expect(Transitions.pageName, '/a/:id');
        return Transitions.none(_key, const SizedBox());
      });
      expect(page.name, '/a/:id');
      expect(Transitions.pageName, isNull);
      // Outside it a page has no name, as before.
      expect(Transitions.none(_key, const SizedBox()).name, isNull);
    });

    test('returns what the builder returned, the very object', () {
      final built = Transitions.none(_key, const SizedBox());
      expect(identical(namedPage('/a', () => built), built), isTrue);
    });

    test('nests, and brings the outer name back, also after a throw', () {
      namedPage('/outer', () {
        namedPage('/inner', () => expect(Transitions.pageName, '/inner'));
        expect(Transitions.pageName, '/outer');
        expect(
          () => namedPage('/failing', () => throw StateError('x')),
          throwsStateError,
        );
        expect(Transitions.pageName, '/outer');
      });
      expect(Transitions.pageName, isNull);
    });

    test('every page of Transitions takes the name', () {
      final pages = namedPage(
        '/p',
        () => <Page<void>>[
          Transitions.fade(_key, const SizedBox()),
          Transitions.slide(_key, const SizedBox()),
          Transitions.none(_key, const SizedBox()),
          Transitions.material(_key, const SizedBox()),
          Transitions.cupertino(_key, const SizedBox()),
          Transitions.dialog(_key, const SizedBox()),
          Transitions.sheet(_key, const SizedBox()),
          Transitions.fullscreenDialog(_key, const SizedBox()),
        ],
      );
      expect(pages.map((p) => p.name), everyElement('/p'));
      expect(pages[4], isA<CupertinoPage<void>>());
    });

    test('a page of your own reads the name from Transitions.pageName', () {
      final page = namedPage(
        '/mine',
        () => _built(
          () => MaterialPage<void>(
            key: _key,
            name: Transitions.pageName,
            child: const SizedBox(),
          ),
        ),
      );
      expect(page.name, '/mine');
    });
  });

  group('observers', () {
    testWidgets(
      'see the pattern of a shell, a page, a push, a dialog and a sheet',
      (tester) async {
        final names = Names();
        final r = router(names);
        addTearDown(r.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: r));
        await tester.pumpAndSettle();
        // The shell, then the page in it (go_router forwards the shell's pushes to the root observers).
        expect(names.pushed, ['/', '/']);

        unawaited(r.push<void>('/products/7'));
        await tester.pumpAndSettle();
        expect(find.text('product 7'), findsOneWidget);
        expect(names.pushed.last, '/products/:id');

        r.pop();
        await tester.pumpAndSettle();
        unawaited(r.push<void>('/dialog'));
        await tester.pumpAndSettle();
        expect(find.text('dialog'), findsOneWidget);
        expect(names.pushed.last, '/dialog');

        r.pop();
        await tester.pumpAndSettle();
        unawaited(r.push<void>('/sheet'));
        await tester.pumpAndSettle();
        expect(find.text('sheet'), findsOneWidget);
        expect(names.pushed.last, '/sheet');
        expect(Transitions.pageName, isNull);
      },
    );

    testWidgets('see the pattern of a remount page, not the path template', (
      tester,
    ) async {
      final names = Names();
      final r = router(names);
      addTearDown(r.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: r));
      await tester.pumpAndSettle();
      names.pushed.clear();

      r.go('/items/3');
      await tester.pumpAndSettle();
      expect(find.text('item 3'), findsOneWidget);
      // go_router's own name would have been `items/:id`.
      expect(names.pushed, ['/items/:id']);
    });

    testWidgets('a bare builder route keeps go_router\'s own page name', (
      tester,
    ) async {
      final names = Names();
      final r = router(names);
      addTearDown(r.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: r));
      await tester.pumpAndSettle();
      names.pushed.clear();

      r.go('/bare');
      await tester.pumpAndSettle();
      expect(find.text('bare'), findsOneWidget);
      expect(names.pushed, ['bare']);
    });

    testWidgets(
      'a layout and a remount page outside namedPage are named as before',
      (tester) async {
        final names = Names();
        final r = GoRouter(
          observers: [names],
          routes: [
            ShellRoute(
              pageBuilder: (context, state, child) =>
                  layoutPage(context, state, 'layout:/', child),
              routes: [
                GoRoute(
                  path: '/',
                  builder: (context, state) => const Text('home'),
                  routes: [
                    GoRoute(
                      path: 'items/:id',
                      pageBuilder: (context, state) => remountPage(
                        context,
                        state,
                        remountKey(state, Remount.onSegments, const ['id']),
                        const Text('item'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
        addTearDown(r.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: r));
        await tester.pumpAndSettle();
        // The shell has no name of its own (null), the page below is go_router's.
        expect(names.pushed.first, isNull);
        expect(names.pushed.last, '/');

        r.go('/items/3');
        await tester.pumpAndSettle();
        expect(names.pushed.last, 'items/:id');
      },
    );
  });
}
