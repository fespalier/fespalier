// Data freshness and the data cache (since 0.8.1) on products/$id/data.dart: a `staleTime` of a
// minute, a refetch on resume, and a `dataCache`. No test waits for real time: the fake clock of
// `testWidgets` ages the data, and a `MemoryDataStorage` shared by two `pumpRouter` calls stands
// in for a restart.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/api.dart';
import 'package:shop/app.g.dart';

class CountingApi extends FakeApi {
  final calls = <int, int>{};

  @override
  Future<Product> product(int id) {
    calls[id] = (calls[id] ?? 0) + 1;
    return super.product(id);
  }
}

/// A network that is down.
class OfflineApi extends FakeApi {
  @override
  Future<Product> product(int id) async => throw Exception('offline');
}

/// Lets a load finish: the fake API answers after 500 ms, which a settle alone does not wait for.
Future<void> idle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a product uncovered after its staleTime shows at once, then loads again',
    (tester) async {
      final api = CountingApi();
      final router = AppRoutes.router(initialLocation: '/products/2');
      await pumpRouter(
        tester,
        router,
        overrides: [apiProvider.overrideWithValue(api)],
        settle: false,
      );
      await idle(tester);
      expect(find.text('Ceramic mug'), findsOneWidget);
      expect(api.calls[2], 1);

      // Another product on top: #2 is covered, and still in memory.
      unawaited(router.push('/products/3'));
      await idle(tester);
      expect(find.text('Pour-over kettle'), findsOneWidget);

      // Within the minute, coming back reads what is there.
      await tester.pump(const Duration(seconds: 30));
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Ceramic mug'), findsOneWidget);
      expect(api.calls[2], 1);

      // After it, the old product is on the first frame, and the new one is asked for.
      unawaited(router.push('/products/3'));
      await idle(tester);
      await tester.pump(const Duration(minutes: 2));
      router.pop();
      await tester.pump();
      expect(find.text('Ceramic mug'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Ceramic mug'), findsOneWidget);
      expect(api.calls[2], 2);
      await idle(tester);
      expect(find.text('Ceramic mug'), findsOneWidget);
    },
  );

  testWidgets('coming back to the app loads a stale product again', (
    tester,
  ) async {
    final api = CountingApi();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/products/2'),
      overrides: [apiProvider.overrideWithValue(api)],
      settle: false,
    );
    await idle(tester);
    Future<void> resume() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await idle(tester);
    }

    await tester.pump(const Duration(seconds: 20));
    await resume();
    expect(api.calls[2], 1);
    await tester.pump(const Duration(minutes: 1));
    await resume();
    expect(api.calls[2], 2);
    expect(find.text('Ceramic mug'), findsOneWidget);
  });

  testWidgets('an invalidation loads at once, whatever the staleTime', (
    tester,
  ) async {
    final api = CountingApi();
    final container = await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/products/2'),
      overrides: [apiProvider.overrideWithValue(api)],
      settle: false,
    );
    await idle(tester);
    expect(api.calls[2], 1);
    container.invalidate(ProductRoute.data(2));
    await tester.pump();
    // Asked for at once, well inside the minute.
    expect(api.calls[2], 2);
    await idle(tester);
  });

  testWidgets('a restart shows the saved product, and not error.dart, offline',
      (
    tester,
  ) async {
    final storage = MemoryDataStorage();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/products/1'),
      overrides: [dataCacheStorage.overrideWithValue(storage)],
      settle: false,
    );
    await idle(tester);
    expect(find.text('Coffee beans, 500 g'), findsOneWidget);

    // A new start: new router, new container, the same storage, and no network.
    await tester.pumpWidget(const SizedBox());
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/products/1'),
      overrides: [
        apiProvider.overrideWithValue(OfflineApi()),
        dataCacheStorage.overrideWithValue(storage),
      ],
      settle: false,
    );
    expect(find.text('Coffee beans, 500 g'), findsOneWidget);
    await idle(tester);
    expect(find.text('Coffee beans, 500 g'), findsOneWidget);
    expect(find.textContaining('offline'), findsNothing);

    // Without a saved product there is nothing to show, so error.dart is.
    await tester.pumpWidget(const SizedBox());
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/products/2'),
      overrides: [
        apiProvider.overrideWithValue(OfflineApi()),
        dataCacheStorage.overrideWithValue(storage),
      ],
      settle: false,
    );
    await idle(tester);
    expect(find.textContaining('offline'), findsOneWidget);
  });

  testWidgets('the restored product is on the first frame, before the network',
      (
    tester,
  ) async {
    final storage = MemoryDataStorage();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/products/3'),
      overrides: [dataCacheStorage.overrideWithValue(storage)],
      settle: false,
    );
    await idle(tester);
    await tester.pumpWidget(const SizedBox());
    final api = CountingApi();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/products/3'),
      overrides: [
        apiProvider.overrideWithValue(api),
        dataCacheStorage.overrideWithValue(storage),
      ],
      settle: false,
    );
    expect(find.text('Pour-over kettle'), findsOneWidget);
    await idle(tester);
    expect(api.calls[3], 1);
    expect(find.text('Pour-over kettle'), findsOneWidget);
  });
}
