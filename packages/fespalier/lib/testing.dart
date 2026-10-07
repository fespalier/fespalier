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

/// Riverpod's `Override`, the type of the list `overrides` and `pumpRouter(overrides:)` take
/// (since 0.8.1): the setup file of `fsp test` returns a `List<Override>` and imports it from
/// here.
export 'package:hooks_riverpod/misc.dart' show Override;

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
/// [app] builds the widget around the router (since 0.8.1); the default is
/// `MaterialApp.router(routerConfig: router)`. Pass the app's own, `app: AppMain.app` (the
/// generated `lib/app.main.g.dart`, whose `app` builds `lib/app/app.dart`), and a page is tested
/// with the theme, the localizations and the `builder:` it has when it runs. `startup()` does
/// not run here: pass what it would override as [overrides]. To boot all of it, startup
/// included, pump `AppMain.root()` yourself.
///
/// The default app is Flutter's `MaterialApp`. With go_router 18, which looks for
/// `package:material_ui`'s instead, routes without a `transition.dart` don't
/// animate in tests, and go_router's own error screen is unstyled (see docs/getting-started.md, "go_router 18 and Material").
Future<ProviderContainer> pumpRouter(
  WidgetTester tester,
  GoRouter router, {
  List<Override> overrides = const [],
  ProviderContainer? container,
  bool settle = true,
  Duration? Function(int retryCount, Object error)? retry = _noRetry,
  bool disposeRouter = true,
  Widget Function(GoRouter router)? app,
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
      child: app?.call(router) ?? MaterialApp.router(routerConfig: router),
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

/// A [FespalierTelemetry] that keeps what it is told, as lines a test can compare (since 0.8.1).
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
/// #n start navigate LOCATION [source=S]
/// #n start auth STEP backend=NAME [trigger=T] [dpop]
/// #n start image CDN w=WIDTH [preload]
/// #n end OP OUTCOME [async] [-> LOCATION] [status=N] [error=TEXT]
/// #n end navigate OUTCOME [route=P] [kind=K] [from=P] [redirected] [depth=N] [at=LOCATION]
/// #n page enter|focus|leave PATTERN
/// #n within enter|exit
/// ```
///
/// WHAT is the requested location (navigate), the file (guard, redirect, data), `file#name`
/// (action) or `file route=PATTERN` (deferred); `keyed` is data from a family. An auth line
/// (since 0.9.0) names the step (`restore`, `sign_in`, `refresh`, `sign_out`), the backend, what
/// asked for a refresh, and `dpop` when the backend binds its tokens. A navigate line has
/// ` source=S` (since 0.9.0) when [navigateFrom] marked it: `notification`, `shortcut`, `widget`
/// or `link`; the lines of a navigation nobody marked do not change. An image line (since 0.9.0)
/// names the URL builder and the width asked for, and says `preload` when a precache started it;
/// a failed image's end line has `status=N` when the error carried an HTTP status. It never has
/// the URL.
///
/// With [recordWithin] (since 0.9.0) the recorder also writes `within enter` and `within exit`
/// around what runs inside a `data()` or an action ([FespalierTelemetry.within]), so a test can
/// see that a call ran within its operation: add a line to [log] from the code under test, and
/// the order says it. It is off by default, so a log written before 0.9.0 reads the same.
final class RecordingTelemetry extends FespalierTelemetry {
  /// Creates a recorder with an empty [log]. [recordWithin] adds the `within` lines.
  RecordingTelemetry({this.recordWithin = false});

  /// Whether `within enter` and `within exit` lines are written (since 0.9.0).
  final bool recordWithin;

  /// What happened, in order.
  final List<String> log = [];

  final Map<int, TelemetryOp> _ops = {};
  int _last = 0;

  @override
  Object? start(TelemetryStart start) {
    final id = ++_last;
    _ops[id] = start.op;
    final what = switch (start.op) {
      TelemetryOp.navigate =>
        '${start.uri ?? '(commit)'}'
            '${start.source == null ? '' : ' source=${start.source}'}',
      TelemetryOp.action => '${start.site?.file}#${start.site?.name}',
      TelemetryOp.deferred => '${start.file} route=${start.route}',
      TelemetryOp.auth =>
        '${start.authStep} backend=${start.authBackend}'
            '${start.authTrigger == null ? '' : ' trigger=${start.authTrigger}'}'
            '${start.authDpop ? ' dpop' : ''}',
      TelemetryOp.image =>
        '${start.imageCdn} w=${start.imageWidth}'
            '${start.imagePreload ? ' preload' : ''}',
      TelemetryOp.custom => _custom(start.name, start.attributes),
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
      if (end.imageStatus != null) 'status=${end.imageStatus}',
      if (op == TelemetryOp.custom &&
          end.attributes != null &&
          end.attributes!.isNotEmpty)
        _sorted(end.attributes!),
      if (end.error != null) 'error=${end.error}',
    ];
    log.add(parts.join(' '));
  }

  @override
  void page(Object? navigation, TelemetryPage page) {
    log.add('#$navigation page ${page.kind.name} ${page.route}');
  }

  @override
  void within(Object? token, Object? Function() body) {
    if (!recordWithin) {
      body();
      return;
    }
    log.add('#$token within enter');
    try {
      body();
    } finally {
      log.add('#$token within exit');
    }
  }
}

String _sorted(Map<String, Object> attributes) {
  final keys = attributes.keys.toList()..sort();
  return keys.map((k) => '$k=${attributes[k]}').join(' ');
}

String _custom(String? name, Map<String, Object>? attributes) =>
    '${name ?? 'custom'}${attributes == null || attributes.isEmpty ? '' : ' ${_sorted(attributes)}'}';

/// The page of the route whose pattern is [pattern] (`/products/:id`), found by the
/// `Semantics(identifier: 'route:<pattern>')` that `semantics_ids: true` gives it. Needs no
/// semantics tree; a page off screen (underneath another) is skipped (since 0.8.1).
Finder findRoutePage(String pattern) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.identifier == 'route:$pattern',
  description: 'the page of $pattern',
);

/// What `fsp test` runs for each route (since 0.8.1): boots [router] with [pumpRouter] (and
/// [overrides], [app]), pumps on the fake clock until [page] (by default
/// `findRoutePage(pattern)`) is on screen, expects exactly one, then takes the tree down and
/// runs the clock [timeout] on so a fake's pending delay doesn't fail the test.
///
/// The wait is deterministic: it pumps 100 ms of fake time at a time, so a `data.dart` fake that
/// answers after a delay is waited out, and a page that never comes fails after [timeout] of
/// fake time, not real time, naming where the router is. A guard that redirects (no override to
/// get past it), a `data.dart` that fails or never completes, or an exception while building the
/// page keeps it away.
Future<void> smokeTestRoute(
  WidgetTester tester,
  String pattern,
  GoRouter router, {
  Finder? page,
  List<Override> overrides = const [],
  Widget Function(GoRouter router)? app,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final finder = page ?? findRoutePage(pattern);
  await pumpRouter(
    tester,
    router,
    overrides: overrides,
    app: app,
    settle: false,
  );
  const step = Duration(milliseconds: 100);
  var waited = Duration.zero;
  while (finder.evaluate().isEmpty) {
    if (waited >= timeout) {
      String at;
      try {
        at = currentLocation(tester);
      } on Object {
        at = 'unknown';
      }
      fail(
        'The page of $pattern is not on screen after ${timeout.inMilliseconds} ms of fake '
        'time: the router is at $at. A guard that redirects, a data.dart that fails or '
        'never completes, or an exception while building (above) keeps it away.',
      );
    }
    await tester.pump(step);
    waited += step;
  }
  expect(finder, findsOneWidget);
  // Take the tree down and run the clock on: a fake's pending one-shot timer fires with no
  // widget left to react, so the test does not end with "A Timer is still pending".
  await tester.pumpWidget(const SizedBox());
  await tester.pump(timeout);
}
