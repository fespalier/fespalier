import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The restoration id of the page built for [key]: go_router's page keys are
/// `ValueKey<String>`s, and its own pages use the key's value, so these do too.
/// Without one, a page's state is not restored after the app is killed.
String? _restorationId(LocalKey key) => key is ValueKey<String> ? key.value : null;

/// Ready-made pages for `transition.dart`.
///
/// Every page gets a `restorationId` from its key, which is what lets what a
/// page keeps in a `RestorationMixin` survive state restoration. A `Page` you
/// build yourself should pass `restorationId: key.value` too.
abstract final class Transitions {
  /// Cross-fades the page in and out.
  static Page<void> fade(
    LocalKey key,
    Widget child, {
    Duration duration = const Duration(milliseconds: 250),
  }) =>
      CustomTransitionPage<void>(
        key: key,
        restorationId: _restorationId(key),
        child: child,
        transitionDuration: duration,
        reverseTransitionDuration: duration,
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(
          opacity: CurveTween(curve: Curves.easeOut).animate(animation),
          child: child,
        ),
      );

  /// Slides the page in from the [from] edge of the screen (`right` enters
  /// from the right edge, `down` from the bottom, and so on).
  static Page<void> slide(
    LocalKey key,
    Widget child, {
    AxisDirection from = AxisDirection.right,
    Duration duration = const Duration(milliseconds: 300),
  }) {
    final begin = switch (from) {
      AxisDirection.right => const Offset(1, 0),
      AxisDirection.left => const Offset(-1, 0),
      AxisDirection.down => const Offset(0, 1),
      AxisDirection.up => const Offset(0, -1),
    };
    return CustomTransitionPage<void>(
      key: key,
      restorationId: _restorationId(key),
      child: child,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          SlideTransition(
        position: Tween(begin: begin, end: Offset.zero)
            .chain(CurveTween(curve: Curves.easeOutCubic))
            .animate(animation),
        child: child,
      ),
    );
  }

  /// Swaps pages instantly, without any animation.
  static Page<void> none(LocalKey key, Widget child) =>
      NoTransitionPage<void>(key: key, restorationId: _restorationId(key), child: child);

  /// The platform-default Material page transition.
  static Page<void> material(LocalKey key, Widget child) =>
      MaterialPage<void>(key: key, restorationId: _restorationId(key), child: child);

  /// The iOS-style Cupertino page transition (slide plus edge-swipe back).
  static Page<void> cupertino(LocalKey key, Widget child) =>
      CupertinoPage<void>(key: key, restorationId: _restorationId(key), child: child);

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
  }) => _DialogPage(
    key: key,
    restorationId: _restorationId(key),
    child: child,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
    animationStyle: animationStyle,
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
  }) => _SheetPage(
    key: key,
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
  );

  /// A full-screen page that slides up from the bottom, with a close button
  /// in its `AppBar` (a Material page with `fullscreenDialog: true`).
  static Page<void> fullscreenDialog(LocalKey key, Widget child) =>
      MaterialPage<void>(
        key: key,
        restorationId: _restorationId(key),
        child: child,
        fullscreenDialog: true,
      );
}

class _DialogPage extends Page<void> {
  const _DialogPage({
    super.key,
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
    animationStyle: animationStyle,
  );
}

class _SheetPage extends Page<void> {
  const _SheetPage({
    super.key,
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
    sheetAnimationStyle: animationStyle,
  );
}
