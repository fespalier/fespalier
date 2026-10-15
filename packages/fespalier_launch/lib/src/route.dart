import 'package:fespalier/fespalier.dart' show TypedLocation;

import 'action.dart';

/// How an action opens its target (since 0.18.0). A cold start ignores it: the target is the
/// initial location.
enum LaunchOpen {
  /// `router.go`: the target replaces the stack, as a link does.
  go,

  /// `router.push`: the target goes on top of the current page.
  push,
}

/// Where an action goes (since 0.18.0).
final class LaunchTarget {
  /// An action that opens [location] (with the mount prefix), with go_router's [extra].
  LaunchTarget(this.location, {this.extra, this.open = LaunchOpen.go});

  /// An action that opens a typed route: `LaunchTarget.to(OrderRoute(id: 42))`.
  LaunchTarget.to(
    TypedLocation route, {
    Object? extra,
    LaunchOpen open = LaunchOpen.go,
  }) : this(route.location, extra: extra, open: open);

  /// The location, with the mount prefix.
  final String location;

  /// go_router's `extra`.
  final Object? extra;

  /// `go` or `push`; a cold start ignores it.
  final LaunchOpen open;
}

/// The app's mapping from an action to a place (since 0.18.0). Null: the app opens and navigates
/// nowhere. Throwing is reported and counts as null. It must be quick and synchronous: it runs
/// before the first frame on a cold start.
typedef LaunchRoute = LaunchTarget? Function(LaunchAction action);

/// The common mapping for a widget (since 0.18.0): a widget opens the app at a URI whose path is
/// the in-app location (`myapp:///orders/42`), and the path is kept only when [matches] accepts
/// it. The URI must be `https` on one of [hosts], or a scheme in [schemes] whose host is empty or
/// in [hosts]. It must have no credentials, a path that starts with one `/` and is free of control
/// characters and backslashes once decoded. The host, the port and the fragment are dropped, and
/// the query is kept. A shortcut is never mapped by this (it answers null).
///
/// ```dart
/// final widgetRoute = widgetLinkRoute(
///   schemes: {'myapp'},
///   matches: (uri) => AppRoutes.matchUrl(uri) != null,
/// ); // the widget's URI myapp:///orders/42 opens /orders/42
/// ```
LaunchRoute widgetLinkRoute({
  Set<String> schemes = const {},
  Set<String> hosts = const {},
  required bool Function(Uri uri) matches,
  LaunchOpen open = LaunchOpen.go,
}) {
  final allowedSchemes = {for (final s in schemes) s.toLowerCase()};
  final allowedHosts = {for (final h in hosts) h.toLowerCase()};
  return (action) {
    if (action is! WidgetAction) return null;
    final uri = _inApp(action.uri, allowedSchemes, allowedHosts);
    if (uri == null || !matches(uri)) return null;
    return LaunchTarget(uri.toString(), open: open);
  };
}

/// [uri] as an in-app location, or null when it is not one we may open. The rules are
/// [widgetLinkRoute]'s. A widget's URI is untrusted: any app can start the launcher with one.
Uri? _inApp(Uri uri, Set<String> schemes, Set<String> hosts) {
  final scheme = uri.scheme;
  final host = uri.host.toLowerCase();
  if (scheme.isEmpty) return null;
  final allowed = scheme == 'https'
      ? host.isNotEmpty && hosts.contains(host)
      : schemes.contains(scheme) && (host.isEmpty || hosts.contains(host));
  if (!allowed || uri.userInfo.isNotEmpty) return null;
  final path = uri.path;
  if (!path.startsWith('/') || path.startsWith('//')) return null;
  final String decoded;
  try {
    decoded = Uri.decodeFull(path);
  } on FormatException {
    return null;
  }
  if (decoded.startsWith('//')) return null;
  for (final unit in decoded.codeUnits) {
    if (unit < 0x20 || unit == 0x7f || unit == 0x5c) return null;
  }
  try {
    return Uri.parse(uri.hasQuery ? '$path?${uri.query}' : path);
  } on FormatException {
    return null;
  }
}
