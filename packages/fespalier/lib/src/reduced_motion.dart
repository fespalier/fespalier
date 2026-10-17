import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Whether the system asks for reduced motion (since 0.19.0): `MediaQuery.disableAnimations`,
/// the "remove animations" setting on Android and "reduce motion" on iOS.
///
/// Read it from the context of a route or a navigator, when the route is built or its
/// transition is: never when a `Transitions.*` page is made, which happens outside any context.
/// `accessibleNavigation` is not motion and is ignored.
bool reducedMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) == true;

/// The transition of a page route that keeps [build]'s widget tree and its gestures and
/// replaces its motion with a fade of the same `transitionDuration`, which Flutter itself plays
/// at a twentieth while animations are disabled (since 0.19.0).
///
/// [build] is the route's own `buildTransitions` (`super.buildTransitions`), called with an
/// animation that is already complete and a secondary one that is not started, so the page
/// does not move, scale or slide, while the back swipe and the predictive back handler it
/// installs still act on the route's own controller. The page then fades with [animation].
Widget _fadeInPlace(
  Animation<double> animation,
  Widget Function(Animation<double>, Animation<double>) build,
) => FadeTransition(
  opacity: CurveTween(curve: Curves.easeOut).animate(animation),
  child: build(kAlwaysCompleteAnimation, kAlwaysDismissedAnimation),
);

/// A `MaterialPage<void>` whose route fades instead of moving when the system asks for
/// reduced motion (since 0.19.0). It is a `MaterialPage<void>` in every other way.
class ReducedMotionMaterialPage extends MaterialPage<void> {
  /// A Material page with the arguments of [MaterialPage].
  const ReducedMotionMaterialPage({
    required super.child,
    super.fullscreenDialog,
    super.key,
    super.name,
    super.restorationId,
  });

  @override
  Route<void> createRoute(BuildContext context) =>
      _MaterialRoute(page: this, allowSnapshotting: allowSnapshotting);
}

class _MaterialRoute extends PageRoute<void>
    with MaterialRouteTransitionMixin<void> {
  _MaterialRoute({
    required ReducedMotionMaterialPage page,
    super.allowSnapshotting,
  }) : super(settings: page);

  ReducedMotionMaterialPage get _page => settings as ReducedMotionMaterialPage;

  @override
  Widget buildContent(BuildContext context) => _page.child;

  @override
  bool get maintainState => _page.maintainState;

  @override
  bool get fullscreenDialog => _page.fullscreenDialog;

  @override
  String get debugLabel => '${super.debugLabel}(${_page.name})';

  // The page below keeps still under a reduced route. Not a closure when motion is on: the
  // inherited builder (possibly null) is returned unchanged.
  @override
  DelegatedTransitionBuilder? get delegatedTransition {
    final context = navigator?.context;
    if (context != null && reducedMotion(context)) {
      return (
        context,
        animation,
        secondaryAnimation,
        allowSnapshotting,
        child,
      ) => child;
    }
    return super.delegatedTransition;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => reducedMotion(context)
      ? _fadeInPlace(
          animation,
          (primary, secondary) =>
              super.buildTransitions(context, primary, secondary, child),
        )
      : super.buildTransitions(context, animation, secondaryAnimation, child);
}

/// A `CupertinoPage<void>` whose route fades instead of sliding when the system asks for
/// reduced motion (since 0.19.0). It is a `CupertinoPage<void>` in every other way, and the
/// edge swipe back still works.
class ReducedMotionCupertinoPage extends CupertinoPage<void> {
  /// A Cupertino page with the arguments of [CupertinoPage].
  const ReducedMotionCupertinoPage({
    required super.child,
    super.key,
    super.name,
    super.restorationId,
  });

  @override
  Route<void> createRoute(BuildContext context) =>
      _CupertinoRoute(page: this, allowSnapshotting: allowSnapshotting);
}

class _CupertinoRoute extends PageRoute<void>
    with CupertinoRouteTransitionMixin<void> {
  _CupertinoRoute({
    required ReducedMotionCupertinoPage page,
    super.allowSnapshotting,
  }) : super(settings: page);

  ReducedMotionCupertinoPage get _page =>
      settings as ReducedMotionCupertinoPage;

  // The page below slides left under a covering Cupertino route; when reduced it stays put.
  @override
  DelegatedTransitionBuilder? get delegatedTransition => fullscreenDialog
      ? null
      : (context, animation, secondaryAnimation, allowSnapshotting, child) =>
            reducedMotion(context)
            ? child
            : CupertinoPageTransition.delegatedTransition(
                context,
                animation,
                secondaryAnimation,
                allowSnapshotting,
                child,
              );

  @override
  Widget buildContent(BuildContext context) => _page.child;

  @override
  String? get title => _page.title;

  @override
  bool get maintainState => _page.maintainState;

  @override
  bool get fullscreenDialog => _page.fullscreenDialog;

  @override
  String get debugLabel => '${super.debugLabel}(${_page.name})';

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => reducedMotion(context)
      ? _fadeInPlace(
          animation,
          (primary, secondary) =>
              super.buildTransitions(context, primary, secondary, child),
        )
      : super.buildTransitions(context, animation, secondaryAnimation, child);
}
