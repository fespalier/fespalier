// The downloads app through the generated AppAdapters: statuses from the backend, the buttons
// that drive the engine, and a notification tap that opens the detail route, cold and warm. The
// app is AppMain.root(), as main() runs it, with the fakes of fespalier_download in place of the
// HTTP backend and the disk; no network is used.
import 'package:downloads/app.g.dart';
import 'package:downloads/app.main.g.dart';
import 'package:downloads/cases.dart';
import 'package:downloads/setup.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MemoryDownloadStore store;
  late FakeDownloadFiles files;

  setUp(() {
    FespalierDownload.debugReset();
    grantLog.clear();
    store = MemoryDownloadStore();
    files = FakeDownloadFiles();
  });
  tearDown(FespalierDownload.debugReset);

  /// main() on the way to runApp: configure, the adapters' launch() (which opens the engine and
  /// answers a tap that started the app), then the app around the router.
  Future<void> boot(WidgetTester tester, FakeDownloadBackend backend) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    configureDownloads(backend: backend, store: store, files: files);
    final launch = await AppAdapters.launch();
    await tester.pumpWidget(
      AppMain.root(
        router: () => AppRoutes.router(
          launch: launch,
          observers: AppMain.routerObservers(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  String statusOf(WidgetTester tester, String id) =>
      tester.widget<Text>(find.byKey(ValueKey('status-$id'))).data!;

  testWidgets('the list shows each download where the backend says it is', (
    tester,
  ) async {
    store = MemoryDownloadStore({
      'large': StoredDownload(largeCase.request),
      'small': StoredDownload(smallCase.request),
    });
    await boot(
      tester,
      FakeDownloadBackend(
        replay: {
          'large': const Running(1048576, 281018368),
          'small': Complete(smallCase.location, 3655173),
        },
      ),
    );
    expect(statusOf(tester, 'large'), 'Running: 1.0 MB of 268.0 MB (0%)');
    expect(statusOf(tester, 'small'), 'Complete: 3.5 MB, checked');
    expect(statusOf(tester, 'wrong-checksum'), 'Not started');
    // What each status offers.
    expect(find.byKey(const ValueKey('pause-large')), findsOneWidget);
    expect(find.byKey(const ValueKey('remove-small')), findsOneWidget);
    expect(find.byKey(const ValueKey('start-wrong-checksum')), findsOneWidget);
  });

  testWidgets('the buttons start, pause, resume, retry, cancel and remove', (
    tester,
  ) async {
    final backend = FakeDownloadBackend();
    await boot(tester, backend);

    await press(tester, 'start-small');
    expect(backend.enqueued.single.id, 'small');
    expect(backend.enqueued.single.sha256, smallCase.sha256);
    expect(backend.enqueued.single.bytes, smallCase.bytes);
    // The grantor was asked in the foreground, once, and it is not a renewal.
    expect(grantLog, [(id: 'small', renewal: false)]);
    expect(backend.authorizations.single.keys, ['X-Demo-Grant']);

    backend.emit('small', const Running(100, 1000));
    await tester.pumpAndSettle();
    expect(statusOf(tester, 'small'), 'Running: 100 B of 1000 B (10%)');

    await press(tester, 'pause-small');
    expect(backend.paused, ['small']);
    backend.emit('small', const Paused(100, 1000));
    await tester.pumpAndSettle();
    expect(statusOf(tester, 'small'), 'Paused: 100 B of 1000 B');

    await press(tester, 'resume-small');
    expect(backend.resumed, ['small']);

    backend.emit('small', const Failed(DownloadFailure.network));
    await tester.pumpAndSettle();
    expect(statusOf(tester, 'small'), 'Failed (network)');
    await press(tester, 'retry-small');
    expect(backend.enqueued.map((r) => r.id), ['small', 'small']);

    await press(tester, 'cancel-small');
    expect(backend.cancelled, contains('small'));
    expect(statusOf(tester, 'small'), 'Cancelled');

    await press(tester, 'start-small');
    backend.emit('small', Complete(smallCase.location, 3655173));
    await tester.pumpAndSettle();
    await press(tester, 'remove-small');
    expect(statusOf(tester, 'small'), 'Not started');
    expect(files.deleted, contains(smallCase.location));
  });

  testWidgets('the wrong-checksum card asks for a digest of zeros', (
    tester,
  ) async {
    final backend = FakeDownloadBackend();
    await boot(tester, backend);
    await press(tester, 'start-wrong-checksum');
    expect(backend.enqueued.single.sha256, '0' * 64);
    backend.emit('wrong-checksum', const Failed(DownloadFailure.hashMismatch));
    await tester.pumpAndSettle();
    expect(statusOf(tester, 'wrong-checksum'), 'Failed (hashMismatch)');
  });

  testWidgets('a download the app was closed on is Failed (killed) with Retry', (
    tester,
  ) async {
    store = MemoryDownloadStore({'large': StoredDownload(largeCase.request)});
    // The backend mentions nothing and no file is whole: the engine settles it.
    await boot(tester, FakeDownloadBackend());
    expect(statusOf(tester, 'large'), 'Failed (killed)');
    expect(find.byKey(const ValueKey('retry-large')), findsOneWidget);
  });

  testWidgets('sign-out clears every download', (tester) async {
    store = MemoryDownloadStore({'large': StoredDownload(largeCase.request)});
    final backend = FakeDownloadBackend(
      replay: {'large': const Running(10, 100)},
    );
    await boot(tester, backend);
    await press(tester, 'sign-out');
    expect(backend.cancelAllCalls, 1);
    expect(store.clearCalls, 1);
    expect(statusOf(tester, 'large'), 'Not started');
  });

  testWidgets('a cold start from a notification opens the detail page', (
    tester,
  ) async {
    store = MemoryDownloadStore({'large': StoredDownload(largeCase.request)});
    await boot(
      tester,
      FakeDownloadBackend(
        replay: {'large': const Running(5, 100)},
        replayTaps: [('large', DownloadTapKind.body)],
      ),
    );
    expect(currentLocation(tester), '/files/large');
    expect(find.text('Large file (SHA-256 checked)'), findsWidgets);
    final report = tester.widget<SelectableText>(
      find.byKey(const ValueKey('report')),
    );
    expect(report.data, contains('Status: Running: 5 B of 100 B (5%)'));
    expect(report.data, contains('Expected SHA-256: ${largeCase.sha256}'));
  });

  testWidgets('a tap on a download this account does not have goes nowhere', (
    tester,
  ) async {
    await boot(
      tester,
      FakeDownloadBackend(replayTaps: [('ghost', DownloadTapKind.body)]),
    );
    expect(currentLocation(tester), '/');
  });

  testWidgets('a tap while the app runs opens the detail page', (tester) async {
    store = MemoryDownloadStore({'small': StoredDownload(smallCase.request)});
    final backend = FakeDownloadBackend(
      replay: {'small': Complete(smallCase.location, 3655173)},
    );
    await boot(tester, backend);
    expect(currentLocation(tester), '/');
    backend.tap('small');
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/files/small');
    expect(find.byKey(const ValueKey('path')), findsOneWidget);
    expect(find.textContaining('/fake/support/downloads/small.bin'), findsOne);
  });

  testWidgets('the detail page shows the finished file and the partial one', (
    tester,
  ) async {
    store = MemoryDownloadStore({'large': StoredDownload(largeCase.request)});
    files.put(
      DownloadLocation(DownloadBase.support, '${largeCase.path}.part'),
      4096,
    );
    await boot(tester, FakeDownloadBackend());
    await press(tester, 'details-large');
    expect(currentLocation(tester), '/files/large');
    final text = tester
        .widget<SelectableText>(find.byKey(const ValueKey('report')))
        .data!;
    expect(text, contains('File at the destination: none'));
    expect(text, contains('Partial file (.part): 4096 bytes (4.0 KB)'));
    expect(text, contains('Status: Failed (killed)'));
  });
}
