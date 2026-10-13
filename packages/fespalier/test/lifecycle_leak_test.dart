// The lifecycle watch holds the router from an `Expando` and adds one listener to its delegate:
// an app that turns leak tracking on sees nothing of it left behind once the router is disposed.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

final held = Provider.autoDispose<int>((ref) => 1);

void main() {
  LeakTesting.enable();

  testWidgets(
    'an attached router with hooks leaves nothing behind that leak tracking sees',
    experimentalLeakTesting: LeakTesting.settings.withTrackedAll(),
    (tester) async {
      final seen = <String>[];
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Text('home')),
          GoRoute(path: '/other', builder: (_, _) => const Text('other')),
        ],
      );
      observeAttach(
        router,
        (uri) => [
          RouteHooks(
            'observe.dart',
            onEnter: (_, scope) {
              seen.add('enter ${uri.path}');
              // A held subscription and a callback, both gone with the page.
              scope.hold(held);
              scope.onLeave(() => seen.add('scope left ${uri.path}'));
            },
            onLeave: (_) => seen.add('leave ${uri.path}'),
          ),
        ],
      );
      await pumpRouter(tester, router);
      router.go('/other');
      await tester.pumpAndSettle();
      expect(find.text('other'), findsOneWidget);
      expect(seen, ['enter /', 'leave /', 'scope left /', 'enter /other']);
    },
  );
}
