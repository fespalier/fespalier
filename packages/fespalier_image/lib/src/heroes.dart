import 'package:fespalier/fespalier.dart'
    show HeroFlightPath, RouteHeroes, TypedLocation;
import 'package:flutter/widgets.dart';

import 'responsive_image.dart';

/// A route's shared image (since 0.9.0).
extension RouteImageHeroes on TypedLocation {
  /// [child] (a `ResponsiveImage`) as this route's shared element [name], flown with
  /// `ResponsiveImage.flightShuttle`: `RouteHeroes(this).hero(name, shuttle:
  /// ResponsiveImage.flightShuttle, ...)`. Put the same call on both pages.
  ///
  /// The image in flight starts no load and shows the widest variant of its source that is
  /// loaded; without the shuttle, Flutter's default measures the image at every size of the
  /// flight and asks for a new URL several times during one push.
  Widget imageHero(
    Object name, {
    required Widget child,
    bool? onBackGesture,
    HeroFlightPath? path,
  }) => RouteHeroes(this).hero(
    name,
    child: child,
    onBackGesture: onBackGesture,
    path: path,
    shuttle: ResponsiveImage.flightShuttle,
  );
}
