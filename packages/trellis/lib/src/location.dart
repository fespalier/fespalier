import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Base of every generated route class (`ProductRoute(id: 42)`).
abstract class TypedLocation {
  const TypedLocation();

  /// Full location, including the mount prefix.
  String get location;

  void go(BuildContext context) => context.go(location);

  Future<T?> push<T extends Object?>(BuildContext context) =>
      context.push<T>(location);

  void replace(BuildContext context) => context.replace(location);
}

/// Joins a mount prefix (`/shop`) and a route path (`/products/42`).
String joinLocation(String base, String path) {
  if (base.isEmpty || base == '/') return path;
  final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  return path == '/' ? b : '$b$path';
}
