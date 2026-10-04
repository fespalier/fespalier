// The first screen, with `tracing: true`. On Android and iOS Sentry's own app start is the first
// screen's `ui.load` (it covers the time from the process start to the first frame, with the native
// spans): a second one from fespalier for the same screen would be a duplicate. The sink then
// opens none, and tells Sentry's app start when the screen's data is in.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    group('on ${platform.name}, with Sentry\'s defaults', () {
      testWidgets('the first screen opens no transaction of ours, and a later '
          'one does', (tester) async {
        final display = FakeDisplay();
        final rig = Rig(
          tracing: true,
          platform: platform,
          currentDisplay: (_) => display,
        );
        final r = await rig.boot(tester);
        expect(await rig.lines(tester), isEmpty);
        r.go('/other');
        await tester.pumpAndSettle();
        expect(await rig.lines(tester), [
          'transaction ui.load /other status=ok ttid ttfd',
          '  span ui.load.initial_display /other initial display status=ok',
          '  span ui.load.full_display /other full display status=ok',
        ]);
        // The display is the app start's, and only the first screen reports to it.
        expect(display.reported, 1);
      });

      testWidgets('it still names the scope after the first screen', (
        tester,
      ) async {
        final rig = Rig(
          tracing: true,
          platform: platform,
          currentDisplay: (_) => FakeDisplay(),
        );
        await rig.boot(tester);
        expect(rig.sentry.tags['fespalier.route'], '/home');
        expect(rig.sentry.breadcrumbs, ['navigation enter /home']);
      });

      testWidgets('Sentry is told once the data of the first screen is in', (
        tester,
      ) async {
        final answer = Completer<String>();
        load = (_) => answer.future;
        final display = FakeDisplay();
        final rig = Rig(
          tracing: true,
          platform: platform,
          currentDisplay: (_) => display,
        );
        await rig.boot(tester, initial: '/items/1');
        expect(display.reported, 0, reason: 'the page is up, its data is not');
        answer.complete('one');
        await tester.pumpAndSettle();
        expect(display.reported, 1);
        expect(await rig.lines(tester), isEmpty);
      });

      testWidgets('fullDisplay: false never reports to it', (tester) async {
        final display = FakeDisplay();
        final rig = Rig(
          tracing: true,
          fullDisplay: false,
          platform: platform,
          currentDisplay: (_) => display,
        );
        await rig.boot(tester);
        expect(display.reported, 0);
      });
    });
  }

  testWidgets(
    'with standalone app start, the first screen has its transaction',
    (tester) async {
      final rig = Rig(
        tracing: true,
        platform: TargetPlatform.android,
        configure: (options) =>
            // ignore: experimental_member_use
            options.enableStandaloneAppStartTracing = true,
      );
      await rig.boot(tester, keep: true);
      await tester.pump();
      expect(await rig.lines(tester), [
        'transaction ui.load /home status=ok ttid ttfd',
        '  span ui.load.initial_display /home initial display status=ok',
        '  span ui.load.full_display /home full display status=ok',
      ]);
    },
  );

  testWidgets(
    'without Sentry\'s automatic performance tracing the first screen is '
    'an ordinary one',
    (tester) async {
      final rig = Rig(
        tracing: true,
        platform: TargetPlatform.android,
        configure: (options) => options.enableAutoPerformanceTracing = false,
      );
      await rig.boot(tester, keep: true);
      await tester.pump();
      expect(
        await rig.lines(tester),
        contains('transaction ui.load /home status=ok ttid ttfd'),
      );
    },
  );

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('on ${platform.name} the first screen is an ordinary one', (
      tester,
    ) async {
      final rig = Rig(tracing: true, platform: platform);
      await rig.boot(tester, keep: true);
      await tester.pump();
      expect(
        await rig.lines(tester),
        contains('transaction ui.load /home status=ok ttid ttfd'),
      );
    });
  }

  testWidgets('without tracing: true Sentry\'s app start is left alone, on any '
      'platform', (tester) async {
    final display = FakeDisplay();
    final rig = Rig(
      platform: TargetPlatform.android,
      currentDisplay: (_) => display,
    );
    final r = await rig.boot(tester);
    r.go('/other');
    await tester.pumpAndSettle();
    expect(await rig.lines(tester), isEmpty);
    expect(display.reported, 0);
  });
}
