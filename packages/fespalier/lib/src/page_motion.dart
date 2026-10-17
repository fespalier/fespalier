import 'package:flutter/widgets.dart';

/// Which motion a page of `Transitions` plays (since 0.19.0).
///
/// Every `Transitions.*` page carries one, and a page from [Transitions.custom] carries the
/// one it was given (`custom` by default). It is a plain tag on the `Page` object, with no
/// effect on how the page animates: a test reads it with `motionOf` from
/// `package:fespalier/testing.dart`, and a package that builds pages can tell its own from the
/// presets'. A page of the app's own that never went through `Transitions` has none.
///
/// Values are only ever added.
enum PageMotion {
  /// `Transitions.fade`: a cross-fade.
  fade,

  /// `Transitions.slide`: slides in from an edge.
  slide,

  /// `Transitions.none`: no animation.
  none,

  /// `Transitions.material`: the platform-default Material transition.
  material,

  /// `Transitions.cupertino`: the iOS slide with the edge-swipe back.
  cupertino,

  /// `Transitions.dialog`: a Material dialog over the previous page.
  dialog,

  /// `Transitions.sheet`: a modal bottom sheet over the previous page.
  sheet,

  /// `Transitions.fullscreenDialog`: a Material page that slides up.
  fullscreenDialog,

  /// `Transitions.custom`, unless the caller named another motion.
  custom;

  /// The motion [page] was tagged with, or null for a page that `Transitions` did not build.
  ///
  /// A route's `settings` is the `Page` it was made from, so
  /// `PageMotion.of(route.settings as Page)` reads a route's motion. The tag lives on the
  /// page object: a navigation that builds a new page tags the new one.
  static PageMotion? of(Page<dynamic> page) => _tags[page];
}

final Expando<PageMotion> _tags = Expando<PageMotion>('PageMotion');

/// Tags [page] with [motion] and returns it, the very object. Used by `Transitions`; not exported.
T tagMotion<T extends Page<dynamic>>(T page, PageMotion motion) {
  _tags[page] = motion;
  return page;
}
