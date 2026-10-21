// Who listens to the router's delegate before the Router widget does.
//
// A generated app builds its router in `AppRoutes.router()`, which calls `attach(router)`: DevTools'
// listener (`devToolsAttach`, on in every debug build and in `flutter test`) and, with
// `telemetry: true`, `RouterWatch`'s (`telemetryAttach`, on in release too) are on the delegate
// before `MaterialApp.router` builds the Router widget, whose own listener comes last. A router
// that a test builds by hand has nobody in front of the Router, and the order matters: the Router
// registers the post-frame report of the route information it just committed in its own listener,
// so whatever a reader that is listening earlier registers after the commit runs first, and the
// router's report (which replaces the provider's route information with an encoded `Map`) comes
// after it. The tests of a pushed page's guard run in every order, so none of them depends on
// which reader judges a commit first (fespalier/fespalier#258, review round 6).
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
  telemetry('telemetry first');

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
  }
  return router;
}

/// Registers [body] once for each order of [AttachFirst]: a group for each, whose tests build
/// their routers with [attached].
void inEveryOrder(void Function() body) {
  for (final how in AttachFirst.values) {
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
