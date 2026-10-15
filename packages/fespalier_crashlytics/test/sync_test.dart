// fespalier must not make apps flaky: with the sink installed a sync guard or `data()` stays sync, a
// Future is never replaced, a reporter that fails costs its reports and never a feature, and nothing
// is left pending (a timer or a frame would fail these tests).
import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  group('the value that comes back is the very one', () {
    test('a sync data() is a value, in the same call', () {
      Rig();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(syncData), 'sync');
    });

    test('a data() that returns a Future gives that Future', () {
      Rig();
      final future = Future<String>.value('x');
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final provider = Provider.autoDispose<Future<String>>(
        (ref) =>
            traceDataCall(ref, 'd1', null, () => future, telemetry: dataSite),
      );
      expect(identical(c.read(provider), future), isTrue);
    });
  });

  group('a reporter that fails', () {
    testWidgets('and throws: the app still navigates, and the report was made '
        'before the throw', (tester) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      final rig = Rig(throwing: true);
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(find.text('failed'), findsOneWidget);
      expect(rig.crash.errors, hasLength(1));
      r.go('/other');
      await tester.pumpAndSettle();
      expect(find.text('other'), findsOneWidget);
    });

    testWidgets('and returns a failed Future: the app still navigates, and no '
        'error is unhandled', (tester) async {
      load = (_) => Future<String>.error(StateError('no such item'));
      final rig = Rig(failing: true);
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(find.text('failed'), findsOneWidget);
      expect(rig.crash.errors, hasLength(1));
      r.go('/other');
      await tester.pumpAndSettle();
      expect(find.text('other'), findsOneWidget);
    });
  });

  testWidgets('after a few navigations nothing is left scheduled', (
    tester,
  ) async {
    final rig = Rig();
    final r = await rig.boot(tester);
    for (final location in ['/items/1', '/other', '/home', '/items/2']) {
      r.go(location);
      await tester.pumpAndSettle();
    }
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
