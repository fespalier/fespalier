// The router StartupGate makes is made once and disposed with the tree: with leak tracking on,
// a GoRouterDelegate left behind fails the test.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

void main() {
  LeakTesting.enable();

  testWidgets(
    'the router is made once, after startup, and disposed with the tree',
    experimentalLeakTesting: LeakTesting.settings.withTrackedAll(),
    (tester) async {
      var made = 0;
      Widget gate() => StartupGate(
        router: () {
          made++;
          return GoRouter(
            routes: [GoRoute(path: '/', builder: (_, _) => const Text('home'))],
          );
        },
        app: (router) => MaterialApp.router(routerConfig: router),
      );
      await tester.pumpWidget(gate());
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(made, 1);
      // A rebuild above the gate does not make another router.
      await tester.pumpWidget(gate());
      expect(made, 1);
      // Taking the tree away disposes the router: nothing is left for the tracker to find.
      await tester.pumpWidget(const SizedBox());
    },
  );
}
