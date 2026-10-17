import 'package:flutter/widgets.dart';

import 'reduced_motion.dart';

// The shared axis and fade through transitions of Material 3's motion spec, over
// `package:flutter/widgets.dart` alone (since 0.19.0): no Material, no Cupertino, no provider and
// no `animations` package, whose 2.x reads Material's theme and whose 3.x reads material_ui's.
// Everything here is driven by the two animations a route gives its page, so there is no
// controller, ticker, timer or listener of our own: `AnimatedBuilder` owns the only listener.

/// The axis a shared axis transition moves along (since 0.19.0).
enum SharedAxis {
  /// Horizontal: pages slide 30 dp sideways, from the trailing edge going forward. In a
  /// right-to-left `Directionality` the movement is mirrored.
  x,

  /// Vertical: pages slide 30 dp up or down.
  y,

  /// Depth: pages scale (the incoming from 0.8, the outgoing to 1.1), with no offset.
  z,
}

/// The colour that paints behind a page while a shared axis or fade through transition plays
/// (since 0.19.0).
///
/// Both pages fade, so without a fill the page below shows through. Set it once above the
/// router, in `MaterialApp.router(builder:)`, and every `Transitions.sharedAxis` and
/// `Transitions.fadeThrough` page reads it:
///
/// ```dart
/// MaterialApp.router(
///   routerConfig: router,
///   builder: (context, child) => MotionFill(
///     color: Theme.of(context).colorScheme.surface,
///     child: child!,
///   ),
/// );
/// ```
///
/// A preset's own `fill:` wins over it. With neither the fill is transparent, and the
/// middle of a transition shows what is under the Navigator (a page's own background fades
/// with it): set a [MotionFill] once.
class MotionFill extends InheritedWidget {
  /// Provides [color] as the fill of the transitions below [child].
  const MotionFill({super.key, required this.color, required super.child});

  /// The fill colour.
  final Color color;

  /// The fill in force at [context], or null without a [MotionFill] above it.
  static Color? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MotionFill>()?.color;

  @override
  bool updateShouldNotify(MotionFill oldWidget) => color != oldWidget.color;
}

// M3 easing tokens, as cubic beziers.
// md.sys.motion.easing.emphasized.decelerate: what enters moves with this.
const Cubic _decelerate = Cubic(0.05, 0.7, 0.1, 1.0);
// md.sys.motion.easing.emphasized.accelerate: what leaves moves with this.
const Cubic _accelerate = Cubic(0.3, 0.0, 0.8, 0.15);

/// How far a shared axis page slides, in logical pixels (dp).
const double _slide = 30;

/// The outgoing page is gone by here, the incoming one fades in from just before it.
const double _outEnd = 0.35;
const double _inStart = 0.3;

/// What one page looks like at one moment of a transition.
class _Look {
  const _Look(this.opacity, [this.offset = Offset.zero, this.scale = 1.0]);

  final double opacity;
  final Offset offset;
  final double scale;
}

/// Where a page is in a transition: [t] runs 0 to 1 over the time the page plays in or out.
class _Phase {
  const _Phase(this.t, {required this.entering, required this.reverse});

  final double t;

  /// The page is coming into view (the incoming page, or a covered page uncovered).
  final bool entering;

  /// The navigation is a pop: the motion mirrors.
  final bool reverse;

  /// The page's own animation: it enters going forward, leaves going in reverse.
  factory _Phase.primary(Animation<double> a) =>
      a.status == AnimationStatus.reverse
      ? _Phase(1 - a.value, entering: false, reverse: true)
      : _Phase(a.value, entering: true, reverse: false);

  /// The animation of the route above: the page leaves as that route comes in, and comes back
  /// as it goes. At rest (value 0) this is the page as it was.
  factory _Phase.secondary(Animation<double> a) =>
      a.status == AnimationStatus.reverse
      ? _Phase(1 - a.value, entering: true, reverse: true)
      : _Phase(a.value, entering: false, reverse: false);
}

double _fadeOut(double t) => 1 - (t / _outEnd).clamp(0.0, 1.0);

double _lerp(double a, double b, double t) => a + (b - a) * t;

_Look _sharedAxisLook(SharedAxis axis, _Phase p, {required bool rtl}) {
  final t = p.t;
  if (axis == SharedAxis.z) {
    if (p.entering) {
      final e = _decelerate.transform(t);
      return _Look(
        ((t - _inStart) / (1 - _inStart)).clamp(0.0, 1.0),
        Offset.zero,
        p.reverse ? _lerp(1.1, 1, e) : _lerp(0.8, 1, e),
      );
    }
    final e = _accelerate.transform(t);
    return _Look(
      _fadeOut(t),
      Offset.zero,
      p.reverse ? _lerp(1, 0.8, e) : _lerp(1, 1.1, e),
    );
  }
  // Forward, the incoming page comes from +30 and the outgoing one leaves to -30; a pop mirrors.
  final sign =
      (p.reverse ? -1.0 : 1.0) * (axis == SharedAxis.x && rtl ? -1.0 : 1.0);
  final double distance;
  final double opacity;
  if (p.entering) {
    distance = sign * _slide * (1 - _decelerate.transform(t));
    opacity = ((t - _inStart) / (1 - _inStart)).clamp(0.0, 1.0);
  } else {
    distance = -sign * _slide * _accelerate.transform(t);
    opacity = _fadeOut(t);
  }
  return _Look(
    opacity,
    axis == SharedAxis.x ? Offset(distance, 0) : Offset(0, distance),
  );
}

_Look _fadeThroughLook(_Phase p) {
  if (!p.entering) return _Look(_fadeOut(p.t));
  const span = 1 - _outEnd;
  final local = ((p.t - _outEnd) / span).clamp(0.0, 1.0);
  return _Look(
    local,
    Offset.zero,
    _lerp(0.92, 1, _decelerate.transform(local)),
  );
}

/// [child] wearing [look]. The wrappers are always there, at their resting values when nothing
/// moves, so the page's elements keep their state from one frame to the next.
Widget _wear(_Look look, Widget child) => Opacity(
  opacity: look.opacity,
  child: Transform.translate(
    offset: look.offset,
    child: Transform.scale(scale: look.scale, child: child),
  ),
);

/// Plays [look] of the page for its own animation, then for the one above it, with a plain
/// cross-fade when the system asks for reduced motion.
Widget _page({
  required BuildContext context,
  required Animation<double> animation,
  required Animation<double> secondaryAnimation,
  required Color? fill,
  required Widget child,
  required _Look Function(_Phase phase, bool rtl) look,
}) {
  final reduced = reducedMotion(context);
  final color = fill ?? MotionFill.maybeOf(context);
  final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
  return AnimatedBuilder(
    animation: Listenable.merge([animation, secondaryAnimation]),
    child: child,
    builder: (context, child) {
      if (reduced) {
        final filled = color == null
            ? child!
            : ColoredBox(color: color, child: child);
        return _wear(_Look(Curves.easeOut.transform(animation.value)), filled);
      }
      // The covered page's content fades over its own fill, and only the page's own animation
      // fades the fill: mid-transition the fill is still there, so what is under the Navigator
      // does not show through, and the fill does not slide or scale with the content.
      final covered = _wear(
        look(_Phase.secondary(secondaryAnimation), rtl),
        child!,
      );
      final filled = color == null
          ? covered
          : ColoredBox(color: color, child: covered);
      return _wear(look(_Phase.primary(animation), rtl), filled);
    },
  );
}

/// The Material 3 shared axis transition of a page (since 0.19.0), for the `transitionsBuilder`
/// of a route: the page you build it for slides 30 dp and fades in (or scales in, on
/// [SharedAxis.z]) as it enters, and out again as it leaves.
///
/// The outgoing half is driven by [secondaryAnimation], the animation of the route above the
/// page. So a page below plays it only when the page itself is built with this transition (or
/// [FadeThroughPageTransition]): each page animates itself.
///
/// The outgoing page fades out over the first 35% and slides 30 dp away; the incoming page fades
/// in from 30% on and slides in from 30 dp. On a pop the roles mirror. [SharedAxis.x] is
/// mirrored in a right-to-left `Directionality`. With the system's reduced motion on it is a
/// plain cross-fade.
///
/// Both pages fade, so [fill] (else the [MotionFill] above, else nothing) paints behind the
/// page. `Transitions.sharedAxis` is this inside a page route that only plays the outgoing half
/// under an opaque page.
class SharedAxisPageTransition extends StatelessWidget {
  /// A shared axis transition of [child] along [axis].
  const SharedAxisPageTransition({
    super.key,
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
    this.axis = SharedAxis.x,
    this.fill,
  });

  /// The route's own animation: 0 to 1 when the page enters, back when it is popped.
  final Animation<double> animation;

  /// The animation of the route above this one.
  final Animation<double> secondaryAnimation;

  /// The axis the page moves along.
  final SharedAxis axis;

  /// The colour behind the page while it moves, or null for [MotionFill]'s, else transparent.
  final Color? fill;

  /// The page.
  final Widget child;

  @override
  Widget build(BuildContext context) => _page(
    context: context,
    animation: animation,
    secondaryAnimation: secondaryAnimation,
    fill: fill,
    child: child,
    look: (phase, rtl) => _sharedAxisLook(axis, phase, rtl: rtl),
  );
}

/// The Material 3 fade through transition of a page (since 0.19.0), for the `transitionsBuilder`
/// of a route: the outgoing page fades out over the first 35%, then the incoming page fades in
/// and scales from 0.92 to 1 over the rest. On a pop the roles mirror.
///
/// The outgoing half is driven by [secondaryAnimation], like [SharedAxisPageTransition]'s, so a
/// page below plays it only when it is itself built with a transition that reads it. With the
/// system's reduced motion on it is a plain cross-fade. [fill] (else the [MotionFill] above,
/// else nothing) paints behind the page. `Transitions.fadeThrough` is this inside a page route
/// that only plays the outgoing half under an opaque page.
class FadeThroughPageTransition extends StatelessWidget {
  /// A fade through transition of [child].
  const FadeThroughPageTransition({
    super.key,
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
    this.fill,
  });

  /// The route's own animation: 0 to 1 when the page enters, back when it is popped.
  final Animation<double> animation;

  /// The animation of the route above this one.
  final Animation<double> secondaryAnimation;

  /// The colour behind the page while it moves, or null for [MotionFill]'s, else transparent.
  final Color? fill;

  /// The page.
  final Widget child;

  @override
  Widget build(BuildContext context) => _page(
    context: context,
    animation: animation,
    secondaryAnimation: secondaryAnimation,
    fill: fill,
    child: child,
    look: (phase, rtl) => _fadeThroughLook(phase),
  );
}
