/// What a generated `AppMenu` uses, and what a `nav.dart` imports (since 0.8.0).
///
/// A library of its own, not part of `package:fespalier/fespalier.dart`, so `Nav` and
/// `NavItem` collide with nothing an app already has:
///
/// ```dart
/// // lib/app/products/nav.dart
/// import 'package:fespalier/nav.dart';
/// import 'package:flutter/material.dart';
///
/// const nav = Nav(label: 'Products', icon: Icons.storefront_outlined, order: 1);
/// ```
library;

export 'src/nav.dart'
    show Nav, NavAccess, NavItem, NavNode, NavRefused, watchNav, watchNavTrail;
