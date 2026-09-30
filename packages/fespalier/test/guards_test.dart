import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('firstRedirect', () {
    test('the first location wins and later guards do not run', () {
      final ran = <String>[];
      final result = firstRedirect([
        () {
          ran.add('a');
          return null;
        },
        () {
          ran.add('b');
          return '/login';
        },
        () {
          ran.add('c');
          return '/other';
        },
      ]);
      expect(result, '/login');
      expect(ran, ['a', 'b']);
    });

    test('is synchronous while every guard is', () {
      expect(firstRedirect([() => null, () => null]), isNull);
      expect(firstRedirect(const []), isNull);
      expect(firstRedirect([() => null, () => '/x']), '/x');
    });

    test('awaits a Future and keeps going in order', () async {
      final ran = <String>[];
      final result = firstRedirect([
        () async {
          ran.add('a');
          return null;
        },
        () {
          ran.add('b');
          return null;
        },
        () async {
          ran.add('c');
          return '/c';
        },
        () {
          ran.add('d');
          return '/d';
        },
      ]);
      expect(result, isA<Future<String?>>());
      expect(await result, '/c');
      expect(ran, ['a', 'b', 'c']);
    });
  });

  group('returnTo', () {
    test('keeps a location inside the app', () {
      expect(returnTo('/members/2?tab=1'), '/members/2?tab=1');
      expect(returnTo('/'), '/');
    });

    test('falls back for null and for anything that leaves the app', () {
      expect(returnTo(null), '/');
      expect(returnTo('', fallback: '/home'), '/home');
      expect(returnTo('members'), '/');
      expect(returnTo('https://evil.example/x'), '/');
      expect(returnTo('//evil.example/x'), '/');
      expect(returnTo(r'/\evil.example'), '/');
      expect(returnTo('javascript:alert(1)', fallback: '/home'), '/home');
    });
  });

  // What the generator relies on: a `redirect` on a page's GoRoute runs for deep
  // links and for navigation, also when the route sits inside a ShellRoute or a
  // StatefulShellRoute, and a nested child goes through its parent's redirect.
  // These routes are written like the generated ones.
  group('go_router runs GoRoute redirects inside shells', () {
    var signedIn = false;
    var ran = <String>[];

    GuardResult login(String uri, String name) {
      ran.add(name);
      return signedIn ? null : '/login?from=${Uri.encodeComponent(uri)}';
    }

    GoRouter build(String initial) => GoRouter(
          initialLocation: initial,
          routes: [
            GoRoute(path: '/login', builder: (c, s) => const Text('login')),
            ShellRoute(
              builder: (c, s, child) => Column(children: [
                const Text('shell'),
                Expanded(child: child),
              ]),
              routes: [
                GoRoute(path: '/', builder: (c, s) => const Text('home')),
                GoRoute(
                  path: '/members',
                  redirect: (c, s) => firstRedirect([
                    () => login(s.uri.toString(), 'group'),
                    () {
                      ran.add('own');
                      return null;
                    },
                  ]),
                  builder: (c, s) => const Text('members'),
                  routes: [
                    // Nested in a guarded page: covered by the parent's redirect.
                    GoRoute(
                      path: 'sub',
                      builder: (c, s) => const Text('sub'),
                    ),
                  ],
                ),
              ],
            ),
            StatefulShellRoute.indexedStack(
              builder: (c, s, shell) => Column(children: [
                Text('tabs ${shell.currentIndex}'),
                Expanded(child: shell),
              ]),
              branches: [
                StatefulShellBranch(routes: [
                  GoRoute(path: '/a', builder: (c, s) => const Text('a')),
                ]),
                StatefulShellBranch(routes: [
                  GoRoute(
                    path: '/b',
                    redirect: (c, s) => login(s.uri.toString(), 'b'),
                    builder: (c, s) => const Text('b'),
                  ),
                ]),
              ],
            ),
          ],
        );

    Future<GoRouter> pump(WidgetTester tester, String initial) async {
      signedIn = false;
      ran = [];
      final router = build(initial);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('a deep link into a ShellRoute', (tester) async {
      await pump(tester, '/members?x=1');
      expect(find.text('login'), findsOneWidget);
      expect(ran, ['group']);
    });

    testWidgets('a deep link into a StatefulShellRoute branch', (tester) async {
      await pump(tester, '/b');
      expect(find.text('login'), findsOneWidget);
    });

    testWidgets('navigating inside a shell', (tester) async {
      final router = await pump(tester, '/');
      router.go('/members');
      await tester.pumpAndSettle();
      expect(find.text('login'), findsOneWidget);

      signedIn = true;
      router.go('/members');
      await tester.pumpAndSettle();
      expect(find.text('members'), findsOneWidget);
      expect(find.text('shell'), findsOneWidget);
    });

    testWidgets('guards run in order and a nested child reuses its parent',
        (tester) async {
      final router = await pump(tester, '/');
      signedIn = true;
      ran.clear();
      router.go('/members/sub');
      await tester.pumpAndSettle();
      expect(find.text('sub'), findsOneWidget);
      // One pass over the guards of /members: none runs twice for /members/sub.
      expect(ran, ['group', 'own']);
    });

    testWidgets('switching tabs runs the branch guard', (tester) async {
      final router = await pump(tester, '/a');
      expect(find.text('a'), findsOneWidget);

      router.go('/b');
      await tester.pumpAndSettle();
      expect(find.text('login'), findsOneWidget);

      signedIn = true;
      router.go('/b');
      await tester.pumpAndSettle();
      expect(find.text('b'), findsOneWidget);
      expect(find.text('tabs 1'), findsOneWidget);
    });
  });
}
