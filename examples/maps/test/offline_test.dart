// One offline region pack. FakeOfflineTiles is MapLibre's offline database in memory, and the
// test plays MapLibre: progress(), finish(). Nothing is downloaded.
import 'package:fespalier/testing.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maps/app.g.dart';
import 'package:maps/places.dart';
import 'package:maps/region.dart';

void main() {
  late FakeOfflineTiles tiles;

  Future<void> boot(WidgetTester tester) async {
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/offline'),
      overrides: [
        offlineTiles.overrideWithValue(tiles),
        mapSurface.overrideWithValue(FakeMapSurface()),
      ],
    );
  }

  setUp(() => tiles = FakeOfflineTiles(databaseSize: 8192));

  testWidgets('progress runs to complete, then the pack can be deleted', (
    tester,
  ) async {
    await boot(tester);
    expect(find.textContaining('Not on this device'), findsOneWidget);

    await tester.tap(find.text('Download'));
    await tester.pump();
    tiles.progress(
      doualaPack.key,
      0.4,
      completedResources: 40,
      requiredResources: 100,
      bytes: 2048,
    );
    await tester.pump();
    expect(find.text('Downloading 40%'), findsOneWidget);

    tiles.progress(
      doualaPack.key,
      0.9,
      completedResources: 90,
      requiredResources: 100,
      bytes: 4096,
    );
    await tester.pump();
    expect(find.text('Downloading 90%'), findsOneWidget);

    tiles.finish(doualaPack.key, bytes: 6144);
    await tester.pump();
    await tester.pump();
    expect(find.text('On this device (6 KB)'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not on this device'), findsOneWidget);
    expect(tiles.deleted, isNotEmpty);
  });

  testWidgets('pause keeps the progress, resume goes on', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Download'));
    await tester.pump();
    tiles.progress(
      doualaPack.key,
      0.4,
      completedResources: 40,
      requiredResources: 100,
      bytes: 2048,
    );
    await tester.pump();

    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    expect(find.text('Paused at 40%'), findsOneWidget);
    expect(tiles.pauses, hasLength(1));

    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    expect(tiles.resumes, hasLength(1));
    expect(find.textContaining('Downloading'), findsOneWidget);

    tiles.finish(doualaPack.key, bytes: 4096);
    await tester.pump();
    await tester.pump();
    expect(find.text('On this device (4 KB)'), findsOneWidget);
  });

  testWidgets('a pack an earlier session left unfinished is interrupted', (
    tester,
  ) async {
    tiles.seed(doualaPack, complete: false, progress: 0.3, bytes: 500);
    await boot(tester);
    expect(find.text('Interrupted'), findsOneWidget);
    // A region pack does not continue after a restart: this starts the download again.
    expect(find.text('Download again'), findsOneWidget);
  });
}
