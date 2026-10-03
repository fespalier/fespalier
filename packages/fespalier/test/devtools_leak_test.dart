// DevTools support holds a router weakly and adds one listener to its delegate: an app that turns
// leak tracking on sees nothing of it left behind once the router is disposed. The views and
// handles it records as holders of a provider (since 0.8.1) are held weakly too.
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

  testWidgets(
    'a view and a handle recorded as holders are not kept alive by DevTools',
    experimentalLeakTesting: LeakTesting.settings.withTrackedAll(),
    (tester) async {
      final provider = FutureProvider.autoDispose<String>(
        (ref) => traceData(ref, 'd7', null, Future.value('x')),
      );
      late WidgetRef captured;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                captured = ref;
                return DataView<String>(
                  watch: (ref) => watchData(ref, 'd7', provider),
                  refresh: (ref) {},
                  data: Text.new,
                  loading: () => const Text('loading'),
                  error: (e, st, retry) => const Text('error'),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      final handle = captured.prefetchData(provider);
      handle.close();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      // The records only know the view and the handle weakly, so leak tracking finds the
      // disposed states and render objects of the view collected.
      expect(handle.isClosed, isTrue);
    },
  );
}
