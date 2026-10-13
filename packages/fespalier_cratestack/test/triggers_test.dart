// autoSync: a sync on start, on resume, on reconnect and on the app's tick, and on nothing else.
// testWidgets fails a test that leaves a timer behind, which is the proof that nothing here starts one.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_connectivity/fespalier_connectivity.dart';
import 'package:fespalier_connectivity/testing.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [SyncRunner] that only counts why it ran.
final class CountingRunner implements SyncRunner {
  final reasons = <SyncReason>[];
  Future<SyncReport> Function(SyncReason reason)? onSync;

  @override
  Future<SyncReport> sync(SyncReason reason) {
    reasons.add(reason);
    return onSync?.call(reason) ??
        Future.value(SyncReport(reason: reason, reachedServer: true));
  }
}

class _Root extends ConsumerWidget {
  const _Root(this.statuses);
  final List<SyncStatus> statuses;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    statuses.add(ref.watch(autoSync));
    return const SizedBox();
  }
}

Future<ProviderContainer> pumpRoot(
  WidgetTester tester,
  CountingRunner runner, {
  SyncTriggers triggers = const SyncTriggers(),
  List<Override> extra = const [],
  List<SyncStatus>? statuses,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...crateStackTestOverrides(lifecycle: true, triggers: triggers),
        syncRunner.overrideWithValue(runner),
        ...extra,
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: _Root(statuses ?? []),
      ),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(_Root)));
}

Future<void> end(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> background(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
}

Future<void> foreground(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
}

void main() {
  testWidgets('start syncs once, and nothing else does while nothing moves', (
    tester,
  ) async {
    final runner = CountingRunner();
    await pumpRoot(tester, runner);
    await tester.pump();
    await tester.pump();
    expect(runner.reasons, [SyncReason.start]);
    await end(tester);
  });

  testWidgets('a resume syncs', (tester) async {
    final runner = CountingRunner();
    await pumpRoot(tester, runner);
    await background(tester);
    expect(runner.reasons, [SyncReason.start]);
    await foreground(tester);
    expect(runner.reasons, [SyncReason.start, SyncReason.resume]);
    await end(tester);
  });

  testWidgets(
    'no network, then a network (the real ConnectivitySignal) syncs',
    (tester) async {
      final runner = CountingRunner();
      final fake = FakeConnectivity(now: const [ConnectivityResult.none]);
      await pumpRoot(
        tester,
        runner,
        extra: [
          connectivitySource.overrideWithValue(fake),
          reconnectSignal.overrideWith(ConnectivitySignal.new),
        ],
      );
      expect(runner.reasons, [SyncReason.start]);
      fake.online();
      await tester.pump();
      await tester.pump();
      expect(runner.reasons, [SyncReason.start, SyncReason.reconnect]);
      // Wi-Fi to mobile is not a reconnect.
      fake.online(ConnectivityResult.mobile);
      await tester.pump();
      expect(runner.reasons, hasLength(2));
      await end(tester);
    },
  );

  testWidgets('the app\'s ticker syncs', (tester) async {
    final runner = CountingRunner();
    final container = await pumpRoot(
      tester,
      runner,
      extra: [syncTicker.overrideWith(ManualSyncTicker.new)],
    );
    (container.read(syncTicker.notifier) as ManualSyncTicker).tick();
    await tester.pump();
    await tester.pump();
    expect(runner.reasons, [SyncReason.start, SyncReason.tick]);
    await end(tester);
  });

  testWidgets('disabled triggers do nothing', (tester) async {
    final runner = CountingRunner();
    final container = await pumpRoot(
      tester,
      runner,
      triggers: const SyncTriggers(
        onStart: false,
        onResume: false,
        onReconnect: false,
        onTick: false,
      ),
      extra: [syncTicker.overrideWith(ManualSyncTicker.new)],
    );
    (container.read(syncTicker.notifier) as ManualSyncTicker).tick();
    container.read(reconnectSignal.notifier).fire();
    await background(tester);
    await foreground(tester);
    await tester.pump();
    expect(runner.reasons, isEmpty);
    await end(tester);
  });

  testWidgets('only the triggers that are on count', (tester) async {
    final runner = CountingRunner();
    final container = await pumpRoot(
      tester,
      runner,
      triggers: const SyncTriggers(onStart: false, onResume: false),
      extra: [syncTicker.overrideWith(ManualSyncTicker.new)],
    );
    await background(tester);
    await foreground(tester);
    expect(runner.reasons, isEmpty);
    (container.read(syncTicker.notifier) as ManualSyncTicker).tick();
    await tester.pump();
    await tester.pump();
    expect(runner.reasons, [SyncReason.tick]);
    await end(tester);
  });

  testWidgets('the state is the last report, and isSyncing while one runs', (
    tester,
  ) async {
    final runner = CountingRunner();
    final gate = Completer<SyncReport>();
    runner.onSync = (_) => gate.future;
    final statuses = <SyncStatus>[];
    final container = await pumpRoot(tester, runner, statuses: statuses);
    expect(container.read(autoSync).isSyncing, isTrue);
    expect(container.read(autoSync).last, isNull);

    final report = const SyncReport(
      reason: SyncReason.start,
      reachedServer: true,
      pushed: 2,
    );
    gate.complete(report);
    await tester.pump();
    await tester.pump();
    final status = container.read(autoSync);
    expect(status.isSyncing, isFalse);
    expect(status.last, same(report));
    await end(tester);
  });

  testWidgets('a runner that throws leaves a status, not an error', (
    tester,
  ) async {
    final runner = CountingRunner()
      ..onSync = (_) => Future.error(StateError('boom'));
    final container = await pumpRoot(tester, runner);
    await tester.pump();
    await tester.pump();
    expect(container.read(autoSync).isSyncing, isFalse);
    expect(container.read(autoSync).last, isNull);
    await end(tester);
  });

  testWidgets('with the real engine: a tick pushes what an offline edit left', (
    tester,
  ) async {
    final server = FakeRowServer();
    await pumpRealEngine(tester, server);
    await end(tester);
  });

  testWidgets('a skipped sync does not replace the last real report', (
    tester,
  ) async {
    final runner = CountingRunner();
    const real = SyncReport(
      reason: SyncReason.start,
      reachedServer: true,
      pushed: 3,
    );
    runner.onSync = (reason) => Future.value(
      reason == SyncReason.start ? real : SyncReport.skipped(reason),
    );
    final container = await pumpRoot(
      tester,
      runner,
      extra: [syncTicker.overrideWith(ManualSyncTicker.new)],
    );
    await tester.pump();
    expect(container.read(autoSync).last, same(real));
    (container.read(syncTicker.notifier) as ManualSyncTicker).tick();
    await tester.pump();
    await tester.pump();
    expect(runner.reasons, [SyncReason.start, SyncReason.tick]);
    expect(container.read(autoSync).last, same(real));
    await end(tester);
  });
}

Future<void> pumpRealEngine(WidgetTester tester, FakeRowServer server) async {
  final transport = FakeCrateStackTransport();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...crateStackTestOverrides(
          transport: transport,
          lifecycle: true,
          rowServer: server,
          collections: const ['notes'],
        ),
        syncTicker.overrideWith(ManualSyncTicker.new),
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: _Root(<SyncStatus>[]),
      ),
    ),
  );
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(_Root)),
  );
  await container.read(ownedRows).edit('notes', 'n1', {
    'title': 'offline edit',
  });
  expect(server.row('notes', 'n1'), isNull);
  // The start sync reached the server; a tick inside the minimum interval would be skipped.
  await tester.pump(const Duration(seconds: 11));
  (container.read(syncTicker.notifier) as ManualSyncTicker).tick();
  await tester.pump();
  await tester.pump();
  await tester.pump();
  expect(server.row('notes', 'n1')!.fields['title'], 'offline edit');
}
