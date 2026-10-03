/// Helpers for widget tests of an app built with fespalier.
///
/// A separate library, so `package:fespalier/fespalier.dart` never imports
/// `flutter_test`:
///
/// ```dart
/// import 'package:fespalier/testing.dart';
///
/// testWidgets('opens a product', (tester) async {
///   await pumpRouter(tester, AppRoutes.router(initialLocation: '/products/2'));
///   expect(find.byType(ProductPage), findsOneWidget);
///   expect(currentLocation(tester), '/products/2');
/// });
/// ```
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show Override;

import 'src/deferred.dart';
import 'src/telemetry.dart';

Duration? _noRetry(int retryCount, Object error) => null;

/// Disposes [router] unless the test already did: a second `dispose` is an error.
void _dispose(GoRouter router) {
  try {
    router.dispose();
  } on FlutterError {
    // Disposed by the test itself.
  }
}

/// Boots [router] in a `ProviderScope` and a `MaterialApp.router`, and returns
/// the `ProviderContainer` behind it (for `container.read(...)` in assertions).
///
/// [overrides] replace providers, e.g. a fake API. To share state with code that
/// runs outside the widget tree, pass your own [container] instead; it's yours to
/// dispose. [settle] (on by default) pumps until nothing is scheduled, which waits
/// out delays in fake `data.dart` code. Turn it off to look at a loading view, and
/// `pump` the time you want yourself.
///
/// The container has no retries, so a failing `data.dart` shows its `error.dart`
/// at once and leaves no timer behind; pass [retry] (for example
/// `ProviderContainer.defaultRetry`) to test what the app's own policy does.
///
/// The router comes from `AppRoutes.router(initialLocation: ...)`. Build one per test:
/// a router remembers where it navigated. The test owns it, but `pumpRouter` disposes it
/// when the test ends (since 0.5.0), so `LeakTesting` finds nothing left behind. Disposing
/// it in the test body is fine. To keep disposing it yourself, as tests written for 0.4.x do
/// with an `addTearDown(router.dispose)` registered before this call (those run after this
/// one's, and a second `dispose` throws), pass `disposeRouter: false` (since 0.6.0). A
/// disposed router is gone, so don't share one between tests.
///
/// The code of every deferred route (`const deferred = true;`) is loaded first, on the real
/// event loop (since 0.7.0): a widget test's pumps never run it, so a deferred page behaves
/// as an eager one, and is in the first settled frame. A test that pumps a router of its
/// own calls `await tester.runAsync(AppRoutes.loadDeferred)` before it. An app without
/// deferred routes is booted exactly as before.
///
/// This app is Flutter's `MaterialApp`. With go_router 18, which looks for
/// `package:material_ui`'s instead, routes without a `transition.dart` don't
/// animate in tests, and go_router's own error screen is unstyled (see the README).
Future<ProviderContainer> pumpRouter(
  WidgetTester tester,
  GoRouter router, {
  List<Override> overrides = const [],
  ProviderContainer? container,
  bool settle = true,
  Duration? Function(int retryCount, Object error)? retry = _noRetry,
  bool disposeRouter = true,
}) async {
  assert(
    container == null || overrides.isEmpty,
    'pass overrides to your own ProviderContainer, or leave the container out',
  );
  final used =
      container ?? ProviderContainer(overrides: overrides, retry: retry);
  if (container == null) addTearDown(used.dispose);
  if (disposeRouter) addTearDown(() => _dispose(router));
  // A deferred route's code: `loadLibrary` only completes on the real event loop, which a
  // widget test's pumps don't run.
  if (DeferredLibrary.anyPending) {
    await tester.runAsync(DeferredLibrary.loadAll);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: used,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return used;
}

/// Where the router is now, as a string (`/products/2?tab=info`), for a router
/// booted with [pumpRouter] or `MaterialApp.router`.
///
/// It follows `go`, `pop` and `push`: what a `push` shows is the top of the
/// stack, so that is its location. (go_router keeps the pushed page out of the
/// route information, which keeps showing the page underneath, so this reads the
/// router's current configuration instead.)
String currentLocation(WidgetTester tester) {
  final context = tester.element(find.byType(Navigator).first);
  final router = GoRouter.of(context);
  final matches = router.routerDelegate.currentConfiguration;
  // `lastOrNull` is the leaf: a page pushed inside a shell is in the shell's matches.
  final top = matches.lastOrNull;
  if (top is ImperativeRouteMatch) return top.matches.uri.toString();
  return router.routeInformationProvider.value.uri.toString();
}

/// A [FespalierTelemetry] that keeps what it is told, as lines a test can compare (since 0.8.0).
///
/// Install it with `FespalierTelemetry.install(recording)` in `setUp` and
/// `FespalierTelemetry.install(null)` in `tearDown`. Each operation has a number, `#3`, which
/// ties its start to its end and names the navigation it ran under:
///
/// ```text
/// #1 start navigate /products/1
/// #2 start guard checkout/guard.dart parent=#1
/// #2 end guard pass
/// #1 page enter /products/:id
/// #1 end navigate ok route=/products/:id kind=go
/// ```
///
/// The grammar of a line:
///
/// ```text
/// #n start OP WHAT [keyed] [parent=#m]
/// #n end OP OUTCOME [async] [-> LOCATION] [error=TEXT]
/// #n end navigate OUTCOME [route=P] [kind=K] [from=P] [redirected] [depth=N] [at=LOCATION]
/// #n page enter|focus|leave PATTERN
/// ```
///
/// WHAT is the requested location (navigate), the file (guard, redirect, data), `file#name`
/// (action) or `file route=PATTERN` (deferred); `keyed` is data from a family.
final class RecordingTelemetry extends FespalierTelemetry {
  /// Creates a recorder with an empty [log].
  RecordingTelemetry();

  /// What happened, in order.
  final List<String> log = [];

  final Map<int, TelemetryOp> _ops = {};
  int _last = 0;

  @override
  Object? start(TelemetryStart start) {
    final id = ++_last;
    _ops[id] = start.op;
    final what = switch (start.op) {
      TelemetryOp.navigate => start.uri?.toString() ?? '(commit)',
      TelemetryOp.action => '${start.site?.file}#${start.site?.name}',
      TelemetryOp.deferred => '${start.file} route=${start.route}',
      _ => '${start.site?.file}${start.keyed ? ' keyed' : ''}',
    };
    final parent = start.parent == null ? '' : ' parent=#${start.parent}';
    log.add('#$id start ${start.op.name} $what$parent');
    return id;
  }

  @override
  void end(Object? token, TelemetryEnd end) {
    final op = _ops[token];
    final parts = <String>[
      '#$token end ${op?.name} ${end.outcome}',
      if (end.isAsync) 'async',
      if (end.location != null && op != TelemetryOp.navigate)
        '-> ${end.location}',
      if (op == TelemetryOp.navigate) ...[
        if (end.route != null) 'route=${end.route}',
        if (end.kind != null) 'kind=${end.kind}',
        if (end.from != null) 'from=${end.from}',
        if (end.redirected) 'redirected',
        if (end.depth > 0) 'depth=${end.depth}',
        if (end.location != null) 'at=${end.location}',
      ],
      if (end.error != null) 'error=${end.error}',
    ];
    log.add(parts.join(' '));
  }

  @override
  void page(Object? navigation, TelemetryPage page) {
    log.add('#$navigation page ${page.kind.name} ${page.route}');
  }
}
