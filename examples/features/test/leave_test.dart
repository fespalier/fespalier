// leave.dart (since 0.11.0): docs/new/leave.dart is asked before the new-doc page goes, whatever
// takes it away, and a bottom sheet is how it asks.
import 'dart:async' show unawaited;

import 'package:features/app.g.dart';
import 'package:features/new_doc.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<GoRouter> boot(WidgetTester tester, String location) async {
  final router = AppRoutes.router(initialLocation: location);
  await pumpRouter(tester, router);
  return router;
}

/// The system's back button, as the engine sends it.
Future<void> systemBack(WidgetTester tester) async {
  final message = const JSONMethodCodec().encodeMethodCall(
    const MethodCall('popRoute'),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    message,
    (_) {},
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('with nothing typed the page goes at once', (tester) async {
    final router = await boot(tester, '/docs/new');
    expect(find.text('New doc'), findsOneWidget);
    router.go('/docs');
    await tester.pumpAndSettle();
    expect(find.text('Docs index'), findsOneWidget);
    expect(find.text('Discard this doc?'), findsNothing);
  });

  testWidgets(
      'what is typed is asked about in a sheet, and false keeps the page', (
    tester,
  ) async {
    final router = await boot(tester, '/docs/new');
    await tester.tap(find.text('Type'));
    await tester.pump();
    router.go('/docs');
    await tester.pumpAndSettle();
    expect(find.text('Discard this doc?'), findsOneWidget);
    expect(find.text('New doc'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Discard this doc?'), findsNothing);
    expect(find.text('New doc'), findsOneWidget);

    router.go('/docs');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Docs index'), findsOneWidget);
  });

  testWidgets('saving clears the draft, so the page goes at once again', (
    tester,
  ) async {
    final router = await boot(tester, '/docs/new');
    await tester.tap(find.text('Type'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();
    router.go('/docs');
    await tester.pumpAndSettle();
    expect(find.text('Docs index'), findsOneWidget);
  });

  testWidgets('the back button asks a page pushed over another one', (
    tester,
  ) async {
    final router = await boot(tester, '/docs');
    unawaited(router.push<void>('/docs/new'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Type'));
    await tester.pump();
    await systemBack(tester);
    expect(find.text('Discard this doc?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('New doc'), findsOneWidget);
    await systemBack(tester);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Docs index'), findsOneWidget);
  });

  testWidgets('and the bottom page of the app, where `true` would close it', (
    tester,
  ) async {
    await boot(tester, '/docs/new');
    await tester.tap(find.text('Type'));
    await tester.pump();
    await systemBack(tester);
    expect(find.text('Discard this doc?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('New doc'), findsOneWidget);
  });

  testWidgets('the catch-all beside it is not asked', (tester) async {
    final router = await boot(tester, '/docs/guide');
    final container = ProviderScope.containerOf(
      tester.element(find.text('Doc guide')),
    );
    container.read(newDocDraft.notifier).write('typed');
    router.go('/docs');
    await tester.pumpAndSettle();
    expect(find.text('Discard this doc?'), findsNothing);
    expect(find.text('Docs index'), findsOneWidget);
  });
}
