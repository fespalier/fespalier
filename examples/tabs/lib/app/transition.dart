import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

/// How every route animates in; a folder's own transition.dart overrides it.
/// It covers the tab layout's own page too (the shell), which is what moves
/// aside when a route on the root navigator opens above it.
/// Try Transitions.material, fade, slide or none.
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.cupertino(key, child);
