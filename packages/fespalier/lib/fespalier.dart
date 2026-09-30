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

export 'src/data_view.dart';
export 'src/guards.dart';
export 'src/layout_page.dart';
export 'src/location.dart';
export 'src/not_found.dart';
export 'src/route_info.dart';
export 'src/route_match.dart';
export 'src/route_navigator.dart';
export 'src/route_data.dart';
export 'src/segments.dart';
export 'src/selected_data.dart';
export 'src/tab_options.dart';
export 'src/transitions.dart';
