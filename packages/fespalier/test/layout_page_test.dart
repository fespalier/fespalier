// A layout's page is keyed by its folder, not by the route object go_router builds it from:
// the router a hot reload (or a test) builds again must not replace the shell, and with it
// the state of the layout and of every page inside.
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts how often a layout's state is created.
var created = 0;

class Shell extends StatefulWidget {
  const Shell({super.key, required this.child});

  final Widget child;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  @override
  void initState() {
    super.initState();
    created++;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// What the generator writes for a layout without a transition.dart, in a fresh router
/// (so with fresh route objects) that shares [navigatorKey].
GoRouter router(GlobalKey<NavigatorState> navigatorKey) => GoRouter(
  navigatorKey: navigatorKey,
  routes: [
    ShellRoute(
      pageBuilder: (context, state, child) =>
          layoutPage(context, state, 'layout:/', Shell(child: child)),
      routes: [
        GoRoute(path: '/', builder: (context, state) => const Text('home')),
      ],
    ),
  ],
);

void main() {
  setUp(() => created = 0);

  testWidgets('the layout page has the same key in every router', (
    tester,
  ) async {
    final keys = <LocalKey?>[];
    for (var i = 0; i < 2; i++) {
      final r = GoRouter(
        routes: [
          ShellRoute(
            pageBuilder: (context, state, child) {
              final page = layoutPage(context, state, 'layout:/', child);
              keys.add(page.key);
              return page;
            },
            routes: [GoRoute(path: '/', builder: (_, _) => const Text('home'))],
          ),
        ],
      );
      addTearDown(r.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: r));
    }
    expect(keys, everyElement(const ValueKey<String>('layout:/')));
  });

  testWidgets('building the router again does not replace the shell', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final first = router(navigatorKey);
    addTearDown(first.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: first));
    expect(find.text('home'), findsOneWidget);
    expect(created, 1);

    final second = router(navigatorKey);
    addTearDown(second.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: second));
    await tester.pump();
    expect(find.text('home'), findsOneWidget);
    expect(created, 1);
  });
}
