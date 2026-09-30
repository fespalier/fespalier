import 'package:features/sheet_page.dart';
import 'package:flutter/widgets.dart';

/// This route's page, built by the app: it applies to `/photos/share` only (a
/// folder below it keeps the transition it had) and puts the route on the root
/// navigator. Bound like `transition.dart`: `key`, `child` and `state`.
Page<void> present(LocalKey key, Widget child) =>
    SheetPage<void>(key: key, child: child);
