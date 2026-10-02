// DevTools support holds a router weakly and adds one listener to its delegate: an app that turns
// leak tracking on sees nothing of it left behind once the router is disposed.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/devtools/devtools.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

void main() {
  LeakTesting.enable();

  setUp(debugDevToolsReset);
  tearDown(debugDevToolsReset);

  testWidgets(
    'an attached router leaves nothing behind that leak tracking sees',
    experimentalLeakTesting: LeakTesting.settings.withTrackedAll(),
    (tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Text('home')),
          GoRoute(path: '/other', builder: (_, _) => const Text('other')),
        ],
      );
      devToolsRegister(tree: () => '{}', matchUrl: (_) => null);
      devToolsAttach(router);
      await pumpRouter(tester, router);
      router.go('/other');
      await tester.pumpAndSettle();
      expect(find.text('other'), findsOneWidget);
    },
  );
}
