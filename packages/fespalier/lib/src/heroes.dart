import 'package:flutter/material.dart';

import 'location.dart';

/// The tag of a shared element: the route it shows, by its path (the location without the
/// query, mount prefix included), and a name (since 0.8.1).
///
/// Equal on the list and on the detail page when both name the same route:
/// `ProductRoute(id: 1).heroTag('image')`.
@immutable
final class RouteHeroTag {
  /// A tag for the element [name] of the route at [path].
  const RouteHeroTag(this.path, this.name);

  /// The route's location up to the query: `/products/1`.
  final String path;

  /// What the element is called on the route: `'image'`, or an enum value.
  final Object name;

  @override
  bool operator ==(Object other) =>
      other is RouteHeroTag && other.path == path && other.name == name;

  @override
  int get hashCode => Object.hash(path, name);

  @override
  String toString() => 'RouteHeroTag($path, $name)';
}

/// The path a hero flies along (since 0.8.1).
enum HeroFlightPath {
  /// The navigator's controller decides: an arc in a Material app, a straight line in a
  /// Cupertino one (go_router picks the controller by app type).
  platform,

  /// A Material arc (`MaterialRectArcTween`).
  arc,

  /// A straight line (`RectTween`).
  straight,
}

/// How the shared elements of the pages a `transition.dart` covers fly (since 0.8.1).
///
/// Give it to a `Transitions.*` call as `heroes:`; every [RouteHero] below the page takes
/// these as its defaults.
@immutable
final class Heroes {
  /// Flight options; the defaults are Flutter's own.
  const Heroes({
    this.onBackGesture = false,
    this.path = HeroFlightPath.platform,
    this.shuttle,
  });

  /// Whether heroes follow a back swipe or predictive back (`Hero.transitionOnUserGestures`).
  /// Flutter checks both pages, so set it for both: the root `transition.dart` does.
  final bool onBackGesture;

  /// The path of the flight (`Hero.createRectTween`).
  final HeroFlightPath path;

  /// What is shown while flying (`Hero.flightShuttleBuilder`); the destination's child
  /// by default.
  final HeroFlightShuttleBuilder? shuttle;

  @override
  bool operator ==(Object other) =>
      other is Heroes &&
      other.onBackGesture == onBackGesture &&
      other.path == path &&
      identical(other.shuttle, shuttle);

  @override
  int get hashCode => Object.hash(onBackGesture, path, shuttle);
}

/// Gives the [RouteHero] widgets below it their defaults (since 0.8.1).
///
/// `Transitions.*` put it around the page when given `heroes:`. A `present.dart` page or a
/// `Page` of your own wraps its child in one to get the same.
class RouteHeroScope extends InheritedWidget {
  /// Applies [heroes] to the [RouteHero]s of [child].
  const RouteHeroScope({super.key, required this.heroes, required super.child});

  /// The defaults for the heroes below.
  final Heroes heroes;

  /// The nearest scope's heroes, or `const Heroes()` without one.
  static Heroes of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RouteHeroScope>()?.heroes ??
      const Heroes();

  @override
  bool updateShouldNotify(RouteHeroScope oldWidget) =>
      heroes != oldWidget.heroes;
}

RectTween _arc(Rect? begin, Rect? end) =>
    MaterialRectArcTween(begin: begin, end: end);

RectTween _straight(Rect? begin, Rect? end) =>
    RectTween(begin: begin, end: end);

CreateRectTween? _tween(HeroFlightPath path) => switch (path) {
  HeroFlightPath.platform => null,
  HeroFlightPath.arc => _arc,
  HeroFlightPath.straight => _straight,
};

/// A Flutter [Hero] that stays out of flights while its tab is not shown (since 0.8.1).
///
/// "Not shown" is `TickerMode` off, which go_router's tab container and fespalier's
/// examples set on the tabs they hide; a custom container must do the same. Two tabs can
/// then show the same tag, and a route opened on the root navigator over the tab bar flies
/// from the tab that is shown, instead of failing with Flutter's duplicate-tag error.
///
/// Arguments left null take the nearest [RouteHeroScope]'s. [tag] is any object: usually
/// `route.heroTag('name')`, which `route.hero('name', child: ...)` builds for you.
class RouteHero extends StatelessWidget {
  /// Makes [child] a shared element called [tag].
  const RouteHero({
    super.key,
    required this.tag,
    required this.child,
    this.onBackGesture,
    this.path,
    this.shuttle,
  });

  /// What the element on the other page is called too.
  final Object tag;

  /// The shared element.
  final Widget child;

  /// Overrides [Heroes.onBackGesture].
  final bool? onBackGesture;

  /// Overrides [Heroes.path].
  final HeroFlightPath? path;

  /// Overrides [Heroes.shuttle].
  final HeroFlightShuttleBuilder? shuttle;

  @override
  Widget build(BuildContext context) {
    final heroes = RouteHeroScope.of(context);
    // `TickerMode.valuesOf` is Flutter 3.35+ and the package supports 3.32; `of` still
    // answers the same until the floor moves.
    // ignore: deprecated_member_use
    final shown = TickerMode.of(context);
    return HeroMode(
      enabled: shown,
      child: Hero(
        tag: tag,
        transitionOnUserGestures: onBackGesture ?? heroes.onBackGesture,
        createRectTween: _tween(path ?? heroes.path),
        flightShuttleBuilder: shuttle ?? heroes.shuttle,
        child: child,
      ),
    );
  }
}

/// A route's shared elements: one line on each side of a list to detail flight
/// (since 0.8.1).
///
/// An extension, so a route with a query parameter named `hero` still compiles; it
/// shadows the extension's member, and `RouteHeroes(route).hero(...)` reaches it.
extension RouteHeroes on TypedLocation {
  /// The tag of this route's shared element [name]: its path (no query) and the name.
  RouteHeroTag heroTag(Object name) {
    final at = location.indexOf('?');
    return RouteHeroTag(at < 0 ? location : location.substring(0, at), name);
  }

  /// [child] as this route's shared element [name]: a [RouteHero] tagged [heroTag].
  ///
  /// Put the same call on the page that links to this route and on the page of the route
  /// itself. [onBackGesture], [path] and [shuttle] override the [RouteHeroScope]'s.
  Widget hero(
    Object name, {
    required Widget child,
    bool? onBackGesture,
    HeroFlightPath? path,
    HeroFlightShuttleBuilder? shuttle,
  }) => RouteHero(
    tag: heroTag(name),
    onBackGesture: onBackGesture,
    path: path,
    shuttle: shuttle,
    child: child,
  );
}
