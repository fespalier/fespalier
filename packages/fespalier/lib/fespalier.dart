/// File-tree routing for Flutter.
///
/// Files under `lib/app/` are plain widgets and functions; `fsp gen` wires
/// them together into `lib/app.g.dart`. This library holds what that
/// generated file needs at runtime, and re-exports hooks, Riverpod and
/// go_router so an app can import one package.
library;

export 'package:flutter_hooks/flutter_hooks.dart';
export 'package:go_router/go_router.dart';
export 'package:hooks_riverpod/hooks_riverpod.dart';

export 'src/data_view.dart';
export 'src/guards.dart';
export 'src/location.dart';
export 'src/segments.dart';
export 'src/tab_options.dart';
export 'src/transitions.dart';
