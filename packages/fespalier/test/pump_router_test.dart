// pumpRouter owns the router it boots: nothing it creates for a test outlives the test.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

GoRouter router() => GoRouter(
  routes: [GoRoute(path: '/', builder: (_, _) => const Text('home'))],
);

void main() {
  // An app that turns leak tracking on must not see fespalier's helper leak the router
  // (a GoRouterDelegate that was never disposed).
  LeakTesting.enable();

  testWidgets(
    'the router is disposed when the test ends',
    experimentalLeakTesting: LeakTesting.settings.withTrackedAll(),
    (tester) async {
      await pumpRouter(tester, router());
      expect(find.text('home'), findsOneWidget);
    },
  );

  testWidgets(
    'a router the test disposed itself is not disposed twice',
    experimentalLeakTesting: LeakTesting.settings.withTrackedAll(),
    (tester) async {
      final mine = router();
      await pumpRouter(tester, mine);
      await tester.pumpWidget(const SizedBox());
      mine.dispose();
    },
  );
}
