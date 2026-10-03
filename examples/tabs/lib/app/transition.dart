import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

/// How every route animates in; a folder's own transition.dart overrides it.
/// It covers the tab layout's own page too (the shell), which is what moves
/// aside when a route on the root navigator opens above it.
/// Try Transitions.material, fade, slide or none.
///
/// `heroes:` is how shared elements fly (since 0.8.0): `onBackGesture` lets
/// them follow the iOS edge swipe too. It covers the tab layout's page, so it
/// applies to every page inside the tabs and to the ones above them.
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.cupertino(key, child,
        heroes: const Heroes(onBackGesture: true));
