import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'heroes.dart';
import 'motion.dart';
import 'page_motion.dart';
import 'reduced_motion.dart';

/// The restoration id of the page built for [key]: go_router's page keys are
/// `ValueKey<String>`s, and its own pages use the key's value, so these do too.
/// Without one, a page's state is not restored after the app is killed.
String? _restorationId(LocalKey key) =>
    key is ValueKey<String> ? key.value : null;

/// The pattern of the route whose page is being built, set by [namedPage].
String? _pageName;

/// Builds the page of the route whose pattern is [name] (since 0.9.0): [build] runs once,
/// synchronously, and the pages [Transitions], `layoutPage` and `remountPage` make while it runs
/// are named [name] (`RouteSettings.name`), so a `NavigatorObserver` (Sentry's, Firebase
/// Analytics', PostHog's) sees `/products/:id`. The generated file calls it around each page
/// builder.
///
/// Nothing is left behind: the name in force before is back when [build] returns or throws, and
/// what [build] returns is returned, the very object.
@pragma('vm:prefer-inline')
@pragma('dart2js:tryInline')
T namedPage<T>(String name, T Function() build) {
  final outer = _pageName;
  _pageName = name;
  try {
    return build();
  } finally {
    _pageName = outer;
  }
}

/// [child] inside a [RouteHeroScope] for [heroes], or [child] itself without any, so a
/// page that doesn't opt in builds the tree it always did.
Widget _withHeroes(Heroes? heroes, Widget child) =>
    heroes == null ? child : RouteHeroScope(heroes: heroes, child: child);

Page<void> _motionPage(
  LocalKey key,
  Widget child, {
  required Duration duration,
  required Heroes? heroes,
  required PageMotion motion,
  required RouteTransitionsBuilder transitionsBuilder,
}) => tagMotion(
  _MotionPage(
    key: key,
    name: _pageName,
    restorationId: _restorationId(key),
    child: _withHeroes(heroes, child),
    duration: duration,
    transitionsBuilder: transitionsBuilder,
  ),
  motion,
);

/// The page of `sharedAxis` and `fadeThrough`: an opaque page route like `custom`'s, except that
/// the page below plays its outgoing half only under an opaque page. A route's secondary
/// animation is driven by any `PageRoute` above it, a see-through one included, which would
/// leave the page below invisible behind it.
class _MotionPage extends Page<void> {
  const _MotionPage({
    super.key,
    super.name,
    super.restorationId,
    required this.child,
    required this.duration,
    required this.transitionsBuilder,
  });

  final Widget child;
  final Duration duration;
  final RouteTransitionsBuilder transitionsBuilder;

  @override
  Route<void> createRoute(BuildContext context) => _MotionRoute(this);
}

class _MotionRoute extends PageRoute<void> {
  _MotionRoute(_MotionPage page) : super(settings: page);

  _MotionPage get _page => settings as _MotionPage;

  @override
  Duration get transitionDuration => _page.duration;

  @override
  Duration get reverseTransitionDuration => _page.duration;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) =>
      nextRoute is PageRoute && nextRoute.opaque;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Semantics(
    scopesRoute: true,
    explicitChildNodes: true,
    child: _page.child,
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _page.transitionsBuilder(context, animation, secondaryAnimation, child);

  @override
  String get debugLabel => '${super.debugLabel}(${_page.name})';
}

/// Ready-made pages for `transition.dart`.
///
/// Every page gets a `restorationId` from its key, which is what lets what a
/// page keeps in a `RestorationMixin` survive state restoration. A `Page` you
/// build yourself should pass `restorationId: Transitions.restorationIdOf(key)` too.
///
/// Every page carries a [PageMotion] tag (since 0.19.0), which `motionOf` reads in a test.
/// [custom] builds a page of your own with the same name, restoration id and heroes.
///
/// Every page honours the system's reduced motion (since 0.19.0), read from the route's own
/// context when it is built: [slide] cross-fades, [material], [cupertino] and
/// [fullscreenDialog] fade in place (the back swipe stays), [dialog] and [sheet] open with
/// `AnimationStyle.noAnimation` unless given an `animationStyle`, and `RouteHero` stops flying.
/// [fade] and [none] are unchanged, and so is the [PageMotion] tag. The builder of [custom] is
/// yours: read `MediaQuery.maybeDisableAnimationsOf(context)` in it. There is no app-wide
/// opt-out: a page that wants motion anyway is a `Page` of your own.
///
/// Every page is named by its route's pattern (since 0.9.0), `/products/:id`, which is what a
/// `NavigatorObserver` reads as `RouteSettings.name`; a `Page` you build yourself passes
/// `name: Transitions.pageName` for the same.
///
/// The pages (every one but [dialog] and [sheet]) take `heroes:` (since 0.8.1): how the
/// `RouteHero`s below them fly, see [Heroes]. A `Page` of your own wraps its child in a
/// [RouteHeroScope] to give the same. Flutter flies heroes between page routes only, so a
/// [dialog] or a [sheet] has no `heroes:`: nothing flies into them.
abstract final class Transitions {
  /// The pattern of the route whose page is being built (since 0.9.0), for a `Page` of your own
  /// in a transition.dart or present.dart: `MaterialPage(key: key, name: Transitions.pageName,
  /// child: child)`. Null outside the generated page builders (a test that calls `transition`
  /// itself, say).
  static String? get pageName => _pageName;

  /// The restoration id of the page built for [key] (since 0.19.0): the key's value for the
  /// `ValueKey<String>`s go_router makes, null for any other key. It is the rule every
  /// `Transitions.*` page follows, public for a `Page` of your own that does not go through
  /// [custom]: `MaterialPage(key: key, restorationId: Transitions.restorationIdOf(key), child: child)`.
  static String? restorationIdOf(LocalKey key) => _restorationId(key);

  /// A page of your own with fespalier's conventions (since 0.19.0): the route's pattern as its
  /// name ([pageName]), the restoration id of [restorationIdOf], and [heroes] as the presets
  /// take them. [transitionsBuilder] is what animates it; it is a `CustomTransitionPage`.
  ///
  /// [duration] is how long it plays in, [reverseDuration] (the same by default) how long it
  /// plays out. [motion] is the tag `motionOf` reads in a test, `PageMotion.custom` unless a
  /// package names its own. The rest are `CustomTransitionPage`'s: [opaque] false lets the
  /// page below stay visible, [fullscreenDialog] marks the route as one, and the barrier
  /// options apply to a non-opaque page.
  ///
  /// ```dart
  /// Page<void> transition(LocalKey key, Widget child) => Transitions.custom(
  ///   key,
  ///   child,
  ///   transitionsBuilder: (context, animation, secondary, child) =>
  ///       ScaleTransition(scale: animation, child: child),
  /// );
  /// ```
  static Page<void> custom(
    LocalKey key,
    Widget child, {
    required RouteTransitionsBuilder transitionsBuilder,
    Duration duration = const Duration(milliseconds: 300),
    Duration? reverseDuration,
    Heroes? heroes,
    bool opaque = true,
    bool fullscreenDialog = false,
    Color? barrierColor,
    bool barrierDismissible = false,
    String? barrierLabel,
    PageMotion motion = PageMotion.custom,
  }) => tagMotion(
    CustomTransitionPage<void>(
      key: key,
      name: _pageName,
      restorationId: _restorationId(key),
      child: _withHeroes(heroes, child),
      transitionDuration: duration,
      reverseTransitionDuration: reverseDuration ?? duration,
      transitionsBuilder: transitionsBuilder,
      opaque: opaque,
      fullscreenDialog: fullscreenDialog,
      barrierColor: barrierColor,
      barrierDismissible: barrierDismissible,
      barrierLabel: barrierLabel,
    ),
    motion,
  );

  /// The Material 3 shared axis transition (since 0.19.0): the page slides 30 dp along [axis]
  /// (or scales, on [SharedAxis.z]) while it fades in, and the page below fades out and slides
  /// away. Built over widgets alone, see [SharedAxisPageTransition].
  ///
  /// The page below plays its half only when it is itself a [sharedAxis] page: each page
  /// animates itself, from the animation of the route above it. [fill] (else the [MotionFill]
  /// above the router, else nothing) paints behind the page while it moves. Under the system's
  /// reduced motion it is a cross-fade.
  static Page<void> sharedAxis(
    LocalKey key,
    Widget child, {
    SharedAxis axis = SharedAxis.x,
    Duration duration = const Duration(milliseconds: 300),
    Color? fill,
    Heroes? heroes,
  }) => _motionPage(
    key,
    child,
    duration: duration,
    heroes: heroes,
    motion: PageMotion.sharedAxis,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        SharedAxisPageTransition(
          animation: animation,
          secondaryAnimation: secondaryAnimation,
          axis: axis,
          fill: fill,
          child: child,
        ),
  );

  /// The Material 3 fade through transition (since 0.19.0): the page below fades out, then the
  /// page fades in and scales from 0.92 to 1. See [FadeThroughPageTransition]; [fill], the
  /// outgoing half and reduced motion work as for [sharedAxis].
  static Page<void> fadeThrough(
    LocalKey key,
    Widget child, {
    Duration duration = const Duration(milliseconds: 300),
    Color? fill,
    Heroes? heroes,
  }) => _motionPage(
    key,
    child,
    duration: duration,
    heroes: heroes,
    motion: PageMotion.fadeThrough,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        FadeThroughPageTransition(
          animation: animation,
          secondaryAnimation: secondaryAnimation,
          fill: fill,
          child: child,
        ),
  );

  /// Cross-fades the page in and out.
  static Page<void> fade(
    LocalKey key,
    Widget child, {
    Duration duration = const Duration(milliseconds: 250),
    Heroes? heroes,
  }) => tagMotion(
    CustomTransitionPage<void>(
      key: key,
      name: _pageName,
      restorationId: _restorationId(key),
      child: _withHeroes(heroes, child),
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(
            opacity: CurveTween(curve: Curves.easeOut).animate(animation),
            child: child,
          ),
    ),
    PageMotion.fade,
  );

  /// Slides the page in from the [from] edge of the screen (`right` enters
  /// from the right edge, `down` from the bottom, and so on).
  static Page<void> slide(
    LocalKey key,
    Widget child, {
    AxisDirection from = AxisDirection.right,
    Duration duration = const Duration(milliseconds: 300),
    Heroes? heroes,
  }) {
    final begin = switch (from) {
      AxisDirection.right => const Offset(1, 0),
      AxisDirection.left => const Offset(-1, 0),
      AxisDirection.down => const Offset(0, 1),
      AxisDirection.up => const Offset(0, -1),
    };
    return tagMotion(
      CustomTransitionPage<void>(
        key: key,
        name: _pageName,
        restorationId: _restorationId(key),
        child: _withHeroes(heroes, child),
        transitionDuration: duration,
        reverseTransitionDuration: duration,
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            reducedMotion(context)
            ? FadeTransition(
                opacity: CurveTween(curve: Curves.easeOut).animate(animation),
                child: child,
              )
            : SlideTransition(
                position: Tween(begin: begin, end: Offset.zero)
                    .chain(CurveTween(curve: Curves.easeOutCubic))
                    .animate(animation),
                child: child,
              ),
      ),
      PageMotion.slide,
    );
  }

  /// Swaps pages instantly, without any animation.
  static Page<void> none(LocalKey key, Widget child, {Heroes? heroes}) =>
      tagMotion(
        NoTransitionPage<void>(
          key: key,
          name: _pageName,
          restorationId: _restorationId(key),
          child: _withHeroes(heroes, child),
        ),
        PageMotion.none,
      );

  /// The platform-default Material page transition.
  static Page<void> material(LocalKey key, Widget child, {Heroes? heroes}) =>
      tagMotion(
        ReducedMotionMaterialPage(
          key: key,
          name: _pageName,
          restorationId: _restorationId(key),
          child: _withHeroes(heroes, child),
        ),
        PageMotion.material,
      );

  /// The iOS-style Cupertino page transition (slide plus edge-swipe back).
  static Page<void> cupertino(LocalKey key, Widget child, {Heroes? heroes}) =>
      tagMotion(
        ReducedMotionCupertinoPage(
          key: key,
          name: _pageName,
          restorationId: _restorationId(key),
          child: _withHeroes(heroes, child),
        ),
        PageMotion.cupertino,
      );

  /// A route that opens as a Material dialog over the previous page.
  ///
  /// [child] is shown as the dialog itself, the way `showDialog`'s builder is:
  /// give the route's page an `AlertDialog`, a `Dialog` or your own card.
  /// Tapping the barrier (unless [barrierDismissible] is off) or the back
  /// button pops it, so does `context.pop()`, and the page below stays built
  /// and visible around it. Place the route below a page (`photo/page.dart`
  /// above `photo/$id/transition.dart`) so that a deep link has a page to
  /// open over; on its own, the dialog opens over an empty screen.
  ///
  /// Inside a tab, the dialog covers that tab's navigator only, so the
  /// navigation bar stays in reach: put the route outside the tab layout's
  /// folder to cover the whole screen.
  static Page<void> dialog(
    LocalKey key,
    Widget child, {
    bool barrierDismissible = true,
    Color? barrierColor = Colors.black54,
    String? barrierLabel,
    bool useSafeArea = true,
    AnimationStyle? animationStyle,
  }) => tagMotion(
    _DialogPage(
      key: key,
      name: _pageName,
      restorationId: _restorationId(key),
      child: child,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      animationStyle: animationStyle,
    ),
    PageMotion.dialog,
  );

  /// A route that opens as a Material modal bottom sheet over the previous
  /// page. See [dialog] for how pop and deep links behave.
  ///
  /// [child] is the sheet's content; the sheet wraps it in a `Material`. Set
  /// [isScrollControlled] for content that scrolls or needs the full height,
  /// and [showDragHandle] for a drag handle. [enableDrag] and
  /// [isDismissible] control swiping and tapping the barrier away.
  static Page<void> sheet(
    LocalKey key,
    Widget child, {
    bool isScrollControlled = false,
    bool showDragHandle = false,
    bool enableDrag = true,
    bool isDismissible = true,
    bool useSafeArea = false,
    Color? backgroundColor,
    Color? barrierColor,
    String? barrierLabel,
    AnimationStyle? animationStyle,
  }) => tagMotion(
    _SheetPage(
      key: key,
      name: _pageName,
      restorationId: _restorationId(key),
      child: child,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      enableDrag: enableDrag,
      isDismissible: isDismissible,
      useSafeArea: useSafeArea,
      backgroundColor: backgroundColor,
      barrierColor: barrierColor,
      barrierLabel: barrierLabel,
      animationStyle: animationStyle,
    ),
    PageMotion.sheet,
  );

  /// A full-screen page that slides up from the bottom, with a close button
  /// in its `AppBar` (a Material page with `fullscreenDialog: true`).
  static Page<void> fullscreenDialog(
    LocalKey key,
    Widget child, {
    Heroes? heroes,
  }) => tagMotion(
    ReducedMotionMaterialPage(
      key: key,
      name: _pageName,
      restorationId: _restorationId(key),
      child: _withHeroes(heroes, child),
      fullscreenDialog: true,
    ),
    PageMotion.fullscreenDialog,
  );
}

class _DialogPage extends Page<void> {
  const _DialogPage({
    super.key,
    super.name,
    super.restorationId,
    required this.child,
    required this.barrierDismissible,
    required this.barrierColor,
    required this.barrierLabel,
    required this.useSafeArea,
    required this.animationStyle,
  });

  final Widget child;
  final bool barrierDismissible;
  final Color? barrierColor;
  final String? barrierLabel;
  final bool useSafeArea;
  final AnimationStyle? animationStyle;

  // `context` is the Navigator's: it sits above every route, so there is no
  // theme to capture in between.
  @override
  Route<void> createRoute(BuildContext context) => DialogRoute<void>(
    context: context,
    settings: this,
    builder: (_) => child,
    barrierColor: barrierColor,
    barrierDismissible: barrierDismissible,
    barrierLabel:
        barrierLabel ??
        Localizations.of<MaterialLocalizations>(
          context,
          MaterialLocalizations,
        )?.modalBarrierDismissLabel ??
        'Dismiss',
    useSafeArea: useSafeArea,
    animationStyle: reducedMotion(context)
        ? (animationStyle ?? AnimationStyle.noAnimation)
        : animationStyle,
  );
}

class _SheetPage extends Page<void> {
  const _SheetPage({
    super.key,
    super.name,
    super.restorationId,
    required this.child,
    required this.isScrollControlled,
    required this.showDragHandle,
    required this.enableDrag,
    required this.isDismissible,
    required this.useSafeArea,
    required this.backgroundColor,
    required this.barrierColor,
    required this.barrierLabel,
    required this.animationStyle,
  });

  final Widget child;
  final bool isScrollControlled;
  final bool showDragHandle;
  final bool enableDrag;
  final bool isDismissible;
  final bool useSafeArea;
  final Color? backgroundColor;
  final Color? barrierColor;
  final String? barrierLabel;
  final AnimationStyle? animationStyle;

  @override
  Route<void> createRoute(BuildContext context) => ModalBottomSheetRoute<void>(
    settings: this,
    builder: (_) => child,
    isScrollControlled: isScrollControlled,
    showDragHandle: showDragHandle,
    enableDrag: enableDrag,
    isDismissible: isDismissible,
    useSafeArea: useSafeArea,
    backgroundColor: backgroundColor,
    modalBarrierColor: barrierColor,
    barrierLabel:
        barrierLabel ??
        Localizations.of<MaterialLocalizations>(
          context,
          MaterialLocalizations,
        )?.scrimLabel ??
        'Dismiss',
    sheetAnimationStyle: reducedMotion(context)
        ? (animationStyle ?? AnimationStyle.noAnimation)
        : animationStyle,
  );
}
