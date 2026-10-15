// A hand-built router that calls the runtime helpers the way a generated app.g.dart does (the
// harness of fespalier_sentry's support.dart, reduced), and what the tests share around it.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_crashlytics/fespalier_crashlytics.dart';
import 'package:fespalier_crashlytics/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const TelemetrySite guardSite = TelemetrySite(
  'checkout/guard.dart',
  route: '/checkout',
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

/// What the guard of `/checkout` answers next.
FutureOr<String?> Function() checkout = () => null;

/// What `data()` of an item gives.
Future<String> Function(int id) load = (id) async => 'item $id';

final item = FutureProvider.autoDispose.family<String, int>(
  (ref, id) =>
      traceDataCall(ref, 'd1', id, () => load(id), telemetry: dataSite),
);

/// A data load that ends at once with a value.
final Provider<String> syncData = Provider.autoDispose<String>(
  (ref) => traceDataCall(ref, 'd2', null, () => 'sync', telemetry: dataSite),
);

/// An action that fails with a [StateError] for `fail`, refuses a name with a [FieldErrors] for
/// `invalid`, and returns its input otherwise.
final ActionProvider<String, String> rename = actionProvider<String, String>(
  (ref, input) async {
    if (input == 'fail') throw StateError('rename refused');
    if (input == 'invalid') {
      throw const FieldErrors(<String, String>{
        'name': 'taken by bob@example.com',
      });
    }
    return input;
  },
  invalidates: () => const [],
  telemetry: actionSite,
);

Widget page(String label) => Scaffold(body: Text(label));

GoRouter router({String initial = '/home'}) {
  final r = GoRouter(
    initialLocation: initial,
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
      GoRoute(
        path: '/checkout',
        redirect: (_, state) =>
            traceGuard(state, 'g1@3', checkout(), telemetry: guardSite),
        builder: (_, _) => page('checkout'),
      ),
    ],
  );
  telemetryAttach(r, base: () => '/');
  return r;
}

/// A router with `fespalier_crashlytics` installed on a [RecordingCrashlytics]: what each test
/// starts from. [throwing] and [failing] make the reporter break, which the app must not notice.
class Rig {
  Rig({
    bool logs = true,
    bool Function(Object, TelemetryStart)? capture,
    Duration repeatWindow = const Duration(seconds: 30),
    bool throwing = false,
    bool failing = false,
  }) : crash = RecordingCrashlytics(throwing: throwing, failing: failing) {
    sink = FespalierCrashlytics(
      crash,
      logs: logs,
      capture: capture ?? FespalierCrashlytics.unexpected,
      repeatWindow: repeatWindow,
    );
    FespalierTelemetry.install(sink);
  }

  final RecordingCrashlytics crash;
  late final FespalierCrashlytics sink;

  /// Builds the router and shows it. What the first screen reported is forgotten (the keys stay, as
  /// they do in Crashlytics), so a test reads what its own navigation did; [keep] keeps it.
  Future<GoRouter> boot(
    WidgetTester tester, {
    String initial = '/home',
    bool keep = false,
  }) async {
    final r = router(initial: initial);
    await pumpRouter(tester, r);
    await tester.pump();
    if (!keep) crash.clear();
    return r;
  }
}
