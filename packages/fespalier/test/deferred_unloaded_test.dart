// A deferred library nobody loaded, under the widget-test binding: a debug-build error that
// says what to do, not a hang or a pending timer. In a file of its own, so no other test
// has loaded the library first.
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/unloaded_page.dart' deferred as unloaded;

Widget view(DeferredLibrary library) => MaterialApp(
  home: DeferredView(
    library: library,
    page: () => unloaded.UnloadedPage(),
    loading: () => const Text('loading'),
    error: (e, st, retry) => Text('error $e'),
  ),
);

void main() {
  testWidgets('a DeferredView of an unloaded library throws a FlutterError', (
    tester,
  ) async {
    final library = DeferredLibrary(
      unloaded.loadLibrary,
      r'products/$id/page.dart',
    );
    await tester.pumpWidget(view(library));
    final error = tester.takeException();
    expect(error, isA<FlutterError>());
    final parts = (error! as FlutterError).diagnostics
        .map((d) => d.toString())
        .toList();
    expect(parts, [
      r"The code of products/$id/page.dart is not loaded, and a widget test can't load it while it pumps.",
      r"`products/$id/page.dart` is a deferred route (`const deferred = true`): its `loadLibrary()` completes only on the real event loop, which `tester.pump()` doesn't run, so the page would show its loading view and leave a timer pending.",
      'Boot the router with `pumpRouter`, which loads the code of every deferred route first, or call `await tester.runAsync(AppRoutes.loadDeferred)` before pumping a router of your own.',
    ]);
    expect(library.isLoaded, isFalse);
    // A pending timer at the end would fail the test: none proves `loadLibrary` was never
    // called.
  });

  testWidgets('preload() of an unloaded library throws the same error', (
    tester,
  ) async {
    final library = DeferredLibrary(unloaded.loadLibrary, 'x/page.dart');
    expect(library.preload, throwsA(isA<FlutterError>()));
  });

  testWidgets('runAsync loads it, and then the page is in the first frame', (
    tester,
  ) async {
    final library = DeferredLibrary(unloaded.loadLibrary, 'x/page.dart');
    await tester.runAsync(library.load);
    expect(library.isLoaded, isTrue);
    await tester.pumpWidget(view(library));
    expect(find.text('unloaded page'), findsOneWidget);
  });
}
