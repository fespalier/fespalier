import 'package:fespalier/fespalier.dart' show TypedLocation;

import 'message.dart';

/// How a tap opens its target.
enum PushOpen {
  /// `router.go`: the target replaces the stack, as a link does.
  go,

  /// `router.push`: the target goes on top of the current page. A cold start is always the
  /// initial location, whatever this says.
  push,
}

/// Where a tap goes (since 0.13.0).
final class PushTarget {
  /// A tap that opens [location] (with the mount prefix), with go_router's [extra].
  PushTarget(this.location, {this.extra, this.open = PushOpen.go});

  /// A tap that opens a typed route: `PushTarget.to(OrderRoute(id: 42))`.
  PushTarget.to(
    TypedLocation route, {
    Object? extra,
    PushOpen open = PushOpen.go,
  }) : this(route.location, extra: extra, open: open);

  /// The location, with the mount prefix.
  final String location;

  /// go_router's `extra`.
  final Object? extra;

  /// `go` or `push`; a cold start ignores it.
  final PushOpen open;
}

/// The app's mapping from a payload to a place (since 0.13.0). Null: the tap opens the app and
/// navigates nowhere. Throwing is reported and counts as null. It must be quick and synchronous.
typedef PushRoute = PushTarget? Function(PushMessage message);

/// The common mapping (since 0.13.0): the payload's [key] holds an in-app path (`/orders/42`) or
/// an `https` URL on one of [hosts], and it is kept only when [matches] accepts it (pass
/// `(uri) => AppRoutes.matchUrl(uri) != null`). Anything else is ignored, never navigated to: a
/// scheme-relative `//host/x`, a backslash, a control character, a foreign host, a scheme other
/// than https, credentials in the URL. A URL's host and port are dropped; so is its fragment.
///
/// ```dart
/// final pushRoute = linkRoute(
///   hosts: {'shop.example.com'},
///   matches: (uri) => AppRoutes.matchUrl(uri) != null,
/// );
/// ```
PushRoute linkRoute({
  String key = 'link',
  Set<String> hosts = const {},
  required bool Function(Uri uri) matches,
  PushOpen open = PushOpen.go,
}) {
  final allowed = {for (final h in hosts) h.toLowerCase()};
  return (message) {
    final raw = message.data[key];
    if (raw is! String) return null;
    final uri = _inApp(raw, allowed);
    if (uri == null || !matches(uri)) return null;
    return PushTarget(uri.toString(), open: open);
  };
}

/// [raw] as an in-app location, or null when it is not one we may follow.
Uri? _inApp(String raw, Set<String> hosts) {
  if (raw.isEmpty || raw.startsWith('//')) return null;
  for (final unit in raw.codeUnits) {
    if (unit < 0x20 || unit == 0x7f || unit == 0x5c) return null;
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.userInfo.isNotEmpty) return null;
  if (uri.hasScheme || uri.hasAuthority) {
    if (uri.scheme != 'https' || !hosts.contains(uri.host)) return null;
  } else if (!raw.startsWith('/')) {
    return null;
  }
  final path = uri.path.isEmpty ? '/' : uri.path;
  if (path.startsWith('//')) return null;
  return Uri.tryParse(uri.hasQuery ? '$path?${uri.query}' : path);
}
