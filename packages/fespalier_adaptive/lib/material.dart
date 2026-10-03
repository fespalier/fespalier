/// `AdaptiveNavScaffold`: a layout's menu as Material's `NavigationBar`, `NavigationRail` or
/// `NavigationDrawer` by window width (since 0.9.0).
///
/// This library imports `package:flutter/material.dart`; the model (`AdaptiveNav`,
/// `NavBreakpoints`, `AdaptiveNavBuilder`) is in `package:fespalier_adaptive/fespalier_adaptive.dart`
/// and re-exported here, so one import is enough for a layout that uses the scaffold. An app on
/// `package:material_ui` renders the model itself with `AdaptiveNavBuilder`.
///
/// The Material widgets it uses exist in Flutter 3.32, fespalier's floor: `NavigationBar`,
/// `NavigationRail`, `NavigationDrawer` (without `header` and `footer`, which are 3.35), and the
/// `enabled` and `disabled` flags of their destinations.
library;

export 'fespalier_adaptive.dart';
export 'src/material_scaffold.dart' show AdaptiveNavScaffold, defaultNavIcon;
