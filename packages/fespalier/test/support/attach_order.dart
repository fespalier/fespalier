// Who listens to the router's delegate before the Router widget does.
//
// A generated app builds its router in `AppRoutes.router()`, which calls `attach(router)` before
// `MaterialApp.router` builds the Router widget: DevTools' listener (`devToolsAttach`, on in every
// debug build and in `flutter test`) and, with `telemetry: true` or an `observe.dart`, the
// lifecycle watch's (`telemetryAttach`, `observeAttach`, on in release too) are on the delegate
// before the widget's own. A router that a test builds by hand has nobody in front of the widget,
// and the order matters: the widget registers the post-frame report of the route information it
// just committed in its own listener, so whatever a reader that listens earlier registers after the
// commit runs before the report, and the report (which replaces the provider's route information
// with an encoded `Map`) comes after it. The tests of a pushed page's guard run in every order, so
// that none of them depends on which reader judges a commit first (fespalier/fespalier#258).
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// What is listening to the delegate before the Router widget.
enum AttachFirst {
  /// Nothing: the Router widget's listener is the first, as in a router built by hand and in a
  /// release build of an app without telemetry or an `observe.dart`.
  nothing('the Router first'),

  /// `devToolsAttach(router)`, which a generated `AppRoutes.router()` runs in a debug build.
  devTools('DevTools first'),

  /// `telemetryAttach(router)` with a sink installed (an app generated with `telemetry: true`).
  telemetry('telemetry first'),

  /// `observeAttach(router, ...)` (an app with an `observe.dart`): the lifecycle hooks' watch.
  observe('observe first');

  const AttachFirst(this.label);

  /// How the groups of [inEveryOrder] are called.
  final String label;
}

/// The order the current group runs in; [inEveryOrder] sets it.
AttachFirst attachFirst = AttachFirst.nothing;

/// [router], with what the current group says listening to it before the Router widget is built:
/// `await pumpRouter(tester, attached(r))`. A no-op outside [inEveryOrder].
GoRouter attached(GoRouter router) {
  switch (attachFirst) {
    case AttachFirst.nothing:
      break;
    case AttachFirst.devTools:
      devToolsAttach(router);
    case AttachFirst.telemetry:
      telemetryAttach(router, base: () => '');
    case AttachFirst.observe:
      observeAttach(router, (_) => const <RouteHooks>[]);
  }
  return router;
}

/// Registers [body] once for each order of [AttachFirst], or of [orders]: a group for each, whose
/// tests build their routers with [attached]. A test that attaches the lifecycle watch itself
/// (`observeAttach` with hooks of its own) leaves [AttachFirst.observe] out.
void inEveryOrder(
  void Function() body, {
  List<AttachFirst> orders = AttachFirst.values,
}) {
  for (final how in orders) {
    group(how.label, () {
      setUp(() {
        attachFirst = how;
        if (how == AttachFirst.telemetry) {
          FespalierTelemetry.install(RecordingTelemetry());
        }
      });
      tearDown(() {
        attachFirst = AttachFirst.nothing;
        FespalierTelemetry.install(null);
      });
      body();
    });
  }
}
