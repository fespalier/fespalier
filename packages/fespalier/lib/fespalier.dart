/// File-tree routing for Flutter.
///
/// Files under `lib/app/` are plain widgets and functions; `fsp gen` wires
/// them together into `lib/app.g.dart`. This library holds what that
/// generated file needs at runtime, and re-exports hooks, Riverpod and
/// go_router so an app can import one package.
library;

export 'package:flutter_hooks/flutter_hooks.dart';
// go_router's own `RouteMatch` (an internal of its parser) is hidden: fespalier's is
// what `AppRoutes.match` returns. `import 'package:go_router/go_router.dart'` for that one.
export 'package:go_router/go_router.dart' hide RouteMatch;
export 'package:hooks_riverpod/hooks_riverpod.dart';
// What a `data.dart` that selects a provider names in its return type.
export 'package:hooks_riverpod/misc.dart' show ProviderListenable;

export 'src/action.dart';
export 'src/data_view.dart';
export 'src/deferred.dart';
// DevTools support (since 0.7.0): what a generated app.g.dart registers and attaches.
export 'src/devtools/devtools.dart'
    show
        devToolsAttach,
        devToolsRegister,
        kFespalierDevTools,
        traceData,
        traceGuard;
export 'src/extra_codec.dart';
export 'src/guards.dart';
export 'src/layout_page.dart';
// Route lifecycle (since 0.8.0): what a generated app.g.dart builds from observe.dart files.
export 'src/lifecycle.dart' show RouteHooks, observeAttach;
export 'src/location.dart';
export 'src/not_found.dart';
export 'src/remount.dart';
export 'src/route_info.dart' hide pathTemplate;
export 'src/route_link.dart';
export 'src/route_match.dart';
export 'src/route_navigator.dart';
export 'src/route_data.dart';
export 'src/segments.dart';
export 'src/selected_data.dart';
export 'src/tab_options.dart';
// Telemetry (since 0.8.0): a sink an adapter implements, and what a generated app.g.dart passes.
export 'src/telemetry.dart'
    show
        FespalierTelemetry,
        TelemetryEnd,
        TelemetryOp,
        TelemetryOutcome,
        TelemetryPage,
        TelemetryPageKind,
        TelemetrySite,
        TelemetryStart,
        telemetryAttach;
export 'src/transitions.dart';
export 'src/url_state.dart';
export 'src/version.dart';
export 'src/web_semantics.dart';
