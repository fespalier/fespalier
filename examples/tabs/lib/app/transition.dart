import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// How every route animates in; a folder's own transition.dart overrides it.
/// It covers the tab layout's own page too (the shell), which is what moves
/// aside when a route on the root navigator opens above it.
/// Try Transitions.material, fade, slide or none.
///
/// `heroes:` is how shared elements fly (since 0.8.1): `onBackGesture` lets
/// them follow the iOS edge swipe too. It covers the tab layout's page, so it
/// applies to every page inside the tabs and to the ones above them.
///
/// Every route gets an opaque background of its own: a Cupertino route paints
/// a barrier (9% black) below its page, and a page that is only a `Center`
/// draws nothing over it, so the barrier shows as grey, once for each navigator
/// the page sits in (the Library tab's body sits in two).
Page<void> transition(LocalKey key, Widget child) => Transitions.cupertino(
      key,
      Builder(
        builder: (context) => ColoredBox(
            color: Theme.of(context).colorScheme.surface, child: child),
      ),
      heroes: const Heroes(onBackGesture: true),
    );
