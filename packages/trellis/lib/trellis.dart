/// File-tree routing for Flutter.
///
/// User files import only this library: it re-exports hooks, Riverpod and
/// go_router so a `page.dart` stays a few lines long.
library;

export 'package:flutter_hooks/flutter_hooks.dart';
export 'package:go_router/go_router.dart';
export 'package:hooks_riverpod/hooks_riverpod.dart';

export 'src/data_view.dart';
export 'src/failure.dart';
export 'src/files.dart';
export 'src/location.dart';
export 'src/params.dart';
