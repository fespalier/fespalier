// A hand-built router that calls the runtime helpers the way a generated app.g.dart does (the
// harness of fespalier_otel's spans_test.dart), and what the tests share around it.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_sentry/fespalier_sentry.dart';
import 'package:fespalier_sentry/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

const TelemetrySite guardSite = TelemetrySite(
  'checkout/guard.dart',
  route: '/checkout',
);
const TelemetrySite shopGuardSite = TelemetrySite(
  'shop/guard.dart',
  route: '/shop',
);
const TelemetrySite redirectSite = TelemetrySite(
  'old/redirect.dart',
  route: '/old',
);
const TelemetrySite dataSite = TelemetrySite(
  'items/\$id/data.dart',
  route: '/items/:id',
);
const TelemetrySite actionSite = TelemetrySite(
  'items/\$id/action.dart',
  route: '/items/:id',
  name: 'rename',
);

/// The display of Sentry's app start: it only counts the reports.
final class FakeDisplay extends SentryDisplay {
  FakeDisplay() : super(SpanId.newId());

  int reported = 0;

  @override
  Future<void> reportFullyDisplayed() async => reported++;
}

/// What the guard of `/checkout` answers next.
FutureOr<String?> Function() checkout = () => null;

/// What `data()` of an item gives.
Future<String> Function(int id) load = (id) async => 'item $id';

/// A deferred page's library, as the generated file builds one.
DeferredLibrary shopLibrary = DeferredLibrary(
  () async {},
  'shop/page.dart',
  loadsInFakeAsync: true,
  route: '/shop',
);

final item = FutureProvider.autoDispose.family<String, int>(
  (ref, id) =>
      traceDataCall(ref, 'd1', id, () => load(id), telemetry: dataSite),
);

/// A data load that ends at once with a value.
final Provider<String> syncData = Provider.autoDispose<String>(
  (ref) => traceDataCall(ref, 'd2', null, () => 'sync', telemetry: dataSite),
);

Widget page(String label) => Scaffold(body: Text(label));

GoRouter router({
  String initial = '/home',
  List<NavigatorObserver> observers = const [],
}) {
  final r = GoRouter(
    initialLocation: initial,
    observers: observers,
    routes: [
      GoRoute(path: '/home', builder: (_, _) => page('home')),
      GoRoute(
        path: '/items/:id',
        builder: (context, s) => Consumer(
          builder: (context, ref, _) {
            final value = ref.watch(item(int.parse(s.pathParameters['id']!)));
            return page(
              value.when(
                data: (v) => v,
                error: (e, _) => 'failed',
                loading: () => 'loading',
              ),
            );
          },
        ),
      ),
      GoRoute(path: '/other', builder: (_, _) => page('other')),
      GoRoute(path: '/login', builder: (_, _) => page('login')),
      GoRoute(
        path: '/old',
        redirect: (_, state) =>
            traceGuard(state, 'r4', '/other', telemetry: redirectSite),
      ),
      GoRoute(
        path: '/checkout',
        redirect: (_, state) =>
            traceGuard(state, 'g1@3', checkout(), telemetry: guardSite),
        builder: (_, _) => page('checkout'),
      ),
      // The guard loads a deferred page's code, as `/shop` does in a generated app.
      GoRoute(
        path: '/shop',
        redirect: (_, state) => traceGuard(state, 'g2@4', () async {
          await shopLibrary.load();
          return null;
        }(), telemetry: shopGuardSite),
        builder: (context, _) => Consumer(
          builder: (context, ref, _) =>
              page(ref.watch(item(3)).value ?? 'loading'),
        ),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => shell,
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: '/t1', builder: (_, _) => page('t1'))],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/t2', builder: (_, _) => page('t2'))],
          ),
        ],
      ),
    ],
  );
  telemetryAttach(r, base: () => '/');
  return r;
}

/// A router with `fespalier_sentry` installed on a fresh [RecordingSentry]: what each test starts
/// from. Pass [tracing] to make the sink make transactions.
///
/// [platform] is what `defaultTargetPlatform` says for the test (Linux: the first screen is an
/// ordinary one; on Android and iOS Sentry's own app start is it).
class Rig {
  Rig({
    bool tracing = false,
    bool transactions = true,
    bool fullDisplay = true,
    bool breadcrumbs = true,
    bool routeTag = true,
    bool recordLocations = false,
    bool Function(Object, TelemetryStart)? capture,
    Duration repeatWindow = const Duration(seconds: 30),
    TargetPlatform platform = TargetPlatform.linux,
    bool configured = true,
    void Function(SentryFlutterOptions options)? configure,
    SentryDisplay? Function(Hub hub)? currentDisplay,
  }) : sentry = RecordingSentry(
         configure: (options) {
           if (configured) {
             FespalierSentry.configure(options, dsn: dsn, tracing: tracing);
           }
           configure?.call(options);
         },
       ) {
    sink = FespalierSentry(
      hub: sentry.hub,
      tracing: tracing,
      transactions: transactions,
      fullDisplay: fullDisplay,
      breadcrumbs: breadcrumbs,
      routeTag: routeTag,
      recordLocations: recordLocations,
      capture: capture ?? FespalierSentry.unexpected,
      repeatWindow: repeatWindow,
      currentDisplay: currentDisplay,
      platform: platform,
    );
    FespalierTelemetry.install(sink);
  }

  /// The made-up DSN the tests configure the SDK with: nothing is sent to it.
  static const String dsn = 'https://key@sentry.invalid/1';

  final RecordingSentry sentry;
  late final FespalierSentry sink;

  /// Builds the router and shows it. What the first screen sent is forgotten (the breadcrumbs and
  /// the scope stay), so a test reads what its own navigation sent; [keep] keeps it.
  Future<GoRouter> boot(
    WidgetTester tester, {
    String initial = '/home',
    List<NavigatorObserver> observers = const [],
    bool keep = false,
  }) async {
    final r = router(initial: initial, observers: observers);
    await pumpRouter(tester, r);
    await tester.pump();
    if (!keep) sentry.transport.envelopes.clear();
    return r;
  }

  /// What was sent, after the SDK handed it to its transport.
  Future<List<String>> lines(WidgetTester tester) async {
    await tester.pump();
    return sentry.lines();
  }

  /// What was sent, as the JSON the SDK built.
  Future<List<Map<String, Object?>>> sent(WidgetTester tester) async {
    await tester.pump();
    return sentry.sent();
  }

  /// [lines] for a plain `test()`: no widget tree, so what the SDK is still handing to its
  /// transport is waited for with a real zero-length delay.
  Future<List<String>> plainLines() async {
    await Future<void>.delayed(Duration.zero);
    return sentry.lines();
  }

  /// [sent] for a plain `test()`.
  Future<List<Map<String, Object?>>> plainSent() async {
    await Future<void>.delayed(Duration.zero);
    return sentry.sent();
  }
}
