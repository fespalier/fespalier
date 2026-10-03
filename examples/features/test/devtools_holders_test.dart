// DevTools shows who holds a data.dart's provider (since 0.8.1). /catalog/:productId selects the
// app's own provider (a closure over its id), so fespalier follows it through the page's view.
import 'package:features/app.g.dart';
import 'package:fespalier/fespalier.dart';
// The test seam of the DevTools support: what the service extensions answer, without a VM service.
// ignore: implementation_imports
import 'package:fespalier/src/devtools/devtools.dart'
    show debugDevToolsCall, debugDevToolsReset;
// ignore: implementation_imports
import 'package:fespalier/src/devtools/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

Duration? noRetry(int retryCount, Object error) => null;

Future<List<DataRecord>> records() async =>
    SnapshotRecord.fromJson(await debugDevToolsCall(DevToolsMethods.snapshot))
        .data;

Future<HoldersRecord> holders(int id) async => HoldersRecord.fromJson(
      await debugDevToolsCall(DevToolsMethods.holders, {'id': '$id'}),
    );

void main() {
  setUp(debugDevToolsReset);
  tearDown(debugDevToolsReset);

  testWidgets(
    'the page of a selected provider holds it, and leaving frees it',
    (tester) async {
      final router = AppRoutes.router(initialLocation: '/catalog/1');
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          retry: noRetry,
          child: MaterialApp(
            home: mui.MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final record = (await records()).singleWhere(
        (d) => d.via == DataVia.watch && d.key?.text == '1',
      );
      expect(record.provider, isNotNull);
      final answer = await holders(record.id);
      expect(answer.alive, isTrue);
      expect([for (final h in answer.holders) h.kind], [HolderKind.view]);

      // Leave the page, and let Riverpod drop what nothing listens to.
      router.go('/');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.idle();
      final gone = await holders(record.id);
      expect(gone.holders, isEmpty);
      expect(gone.alive, isFalse);
    },
  );
}
