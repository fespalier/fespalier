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
export 'src/action_form.dart';
// The cache of a data.dart's value for the next start (since 0.8.1).
export 'src/data_cache.dart'
    show
        CachedData,
        DataCache,
        MemoryDataStorage,
        cachedData,
        cachedDataFamily,
        dataCacheStorage;
export 'src/data_view.dart';
export 'src/deferred.dart';
// DevTools support (since 0.7.0): what a generated app.g.dart registers and attaches
// (`watchData` since 0.8.1).
export 'src/devtools/devtools.dart'
    show
        devToolsAttach,
        devToolsRegister,
        kFespalierDevTools,
        traceData,
        traceDataCall,
        traceGuard,
        watchData;
export 'src/extra_codec.dart';
// Data freshness (since 0.8.1): `staleTime`, refetch on resume and reconnect.
export 'src/freshness.dart';
export 'src/guards.dart';
export 'src/heroes.dart';
export 'src/layout_page.dart';
// Route lifecycle (since 0.8.1): what a generated app.g.dart builds from observe.dart files.
export 'src/lifecycle.dart' show RouteHooks, observeAttach;
export 'src/location.dart';
export 'src/not_found.dart';
export 'src/optimistic.dart';
export 'src/remount.dart';
export 'src/route_info.dart' hide pathTemplate;
export 'src/route_link.dart';
export 'src/route_match.dart';
export 'src/route_navigator.dart';
export 'src/route_data.dart';
export 'src/scroll_memory.dart';
export 'src/segments.dart';
export 'src/selected_data.dart';
export 'src/tab_options.dart';
// Telemetry (since 0.8.1): a sink an adapter implements, and what a generated app.g.dart passes
// (`NavigationSource`, `navigateFrom` and `TelemetryTrace` since 0.9.0).
export 'src/telemetry.dart'
    show
        FespalierTelemetry,
        NavigationSource,
        TelemetryEnd,
        TelemetryOp,
        TelemetryOutcome,
        TelemetryPage,
        TelemetryPageKind,
        TelemetrySite,
        TelemetryStart,
        TelemetryTrace,
        navigateFrom,
        telemetryAttach;
export 'src/transitions.dart';
export 'src/url_state.dart';
export 'src/version.dart';
export 'src/web_semantics.dart';
