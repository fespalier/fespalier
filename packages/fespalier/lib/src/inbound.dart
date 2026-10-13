import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'location.dart';
import 'telemetry.dart';

/// Where the app was opened from, when a package knows better than the platform (since 0.11.0):
/// a notification tap that cold-started the app, a home-screen shortcut. An adapter answers it
/// from `FespalierAdapter.launch`; `AppRoutes.router(launch:)` builds the router at [location]
/// and marks the first navigation with [source].
///
/// ```dart
/// final launch = InboundLaunch('/orders/42', source: NavigationSource.notification);
/// ```
final class InboundLaunch {
  /// A launch at [location] ([source] is a `NavigationSource` value, asserted).
  InboundLaunch(this.location, {required this.source, this.extra})
    : assert(
        NavigationSource.values.contains(source),
        'InboundLaunch: `$source` is not a NavigationSource value '
        '(notification, shortcut, widget or link)',
      );

  /// A launch at a typed route: `InboundLaunch.to(OrderRoute(id: 42), source: ...)`.
  InboundLaunch.to(TypedLocation route, {required String source, Object? extra})
    : this(route.location, source: source, extra: extra);

  /// Where the router starts, a location with the mount prefix (`/orders/42`).
  final String location;

  /// A `NavigationSource` value: what telemetry reports as `fespalier.navigation.source`.
  final String source;

  /// go_router's `initialExtra`.
  final Object? extra;

  @override
  String toString() => 'InboundLaunch($location, source: $source)';
}

/// A navigation go_router is about to parse, as an adapter's `onEnter` sees it (since 0.11.0).
final class InboundNavigation {
  /// Made by `FespalierAdapters.onEnter` for each adapter.
  InboundNavigation({
    required this.context,
    required this.current,
    required this.next,
    required this.router,
    required this.initial,
    this.source,
  });

  /// go_router's context for the navigation.
  final BuildContext context;

  /// Where the router is.
  final GoRouterState current;

  /// Where it was asked to go.
  final GoRouterState next;

  /// The router.
  final GoRouter router;

  /// The first navigation of [router]: never block it (go_router shows its error page); answer
  /// `FespalierAdapter.launch` instead.
  final bool initial;

  /// `NavigationSource.link` for a platform link (an App Link, a Universal Link or a custom
  /// scheme that Flutter handed the router); null for any other navigation.
  final String? source;
}

/// Whether this build is the web, overridable by a test.
@visibleForTesting
bool? debugInboundWeb;

/// True on the web: a platform link there is the address bar, and a launch would replace it.
bool get inboundIsWeb => debugInboundWeb ?? kIsWeb;

/// Builds the router of the generated `AppRoutes.router` (generated code calls it), since 0.11.0.
///
/// [make] builds the `GoRouter` and receives the launch that applies: [launch], or null on the
/// web, where the address bar is the launch and a launch is never used. With a launch, [make] is
/// expected to start the router at `launch.location` (`overridePlatformDefaultLocation`), over
/// the platform's initial route, and the first navigation is marked with `launch.source`.
///
/// With [links] set (an app with telemetry or adapters) every platform link is marked
/// `NavigationSource.link`, launch or not: each one the running app receives, and, without a
/// launch, a deep link in the platform's initial route (Android hands it over there; iOS delivers
/// it after the first frame, as a link received while running). Never on the web. [make] runs
/// once, synchronously, and what it builds is returned. With [links] off, no listener is added
/// and nothing is marked.
GoRouter launchRouter(
  InboundLaunch? launch,
  GoRouter Function(InboundLaunch? launch) make, {
  bool links = false,
}) {
  final web = inboundIsWeb;
  final effective = web ? null : launch;
  assert(
    launch == null || !web,
    'launchRouter: a launch is not used on the web (the address bar is the '
    'launch); FespalierAdapters.launch() answers null there',
  );
  GoRouter build() => effective == null
      ? make(null)
      : navigateFrom(effective.source, () => make(effective));
  if (web || !links) return build();
  final binding = WidgetsBinding.instance;
  // Before make(): go_router's provider registers itself with the binding on its first listener,
  // and a binding observer added first hears a platform link first.
  _links.register(binding);
  _links.making = true;
  try {
    final router = effective != null ? build() : _coldStart(binding, make);
    _links.add(router);
    return router;
  } finally {
    _links.making = false;
  }
}

GoRouter _coldStart(
  WidgetsBinding binding,
  GoRouter Function(InboundLaunch? launch) make,
) {
  final platform = Uri.parse(binding.platformDispatcher.defaultRouteName);
  // go_router's own test: an empty path is the root, and only the string `/` is not a link.
  final root = (platform.hasEmptyPath ? platform.replace(path: '/') : platform)
      .toString();
  if (root == '/') return make(null);
  _links.record(platform);
  return navigateFrom(NavigationSource.link, () => make(null));
}

/// `NavigationSource.link` when the platform handed the router [uri] and nothing consumed it yet
/// (a peek: telemetry's navigation start asks, then `onEnter`); null otherwise, and always null
/// for a router `launchRouter` did not make with `links: true`. [router] is null while the router
/// is being made.
String? platformLinkSource(Uri uri, GoRouter? router) {
  if (!_links.linked(router)) return null;
  return _links.matches(uri) ? NavigationSource.link : null;
}

/// Like [platformLinkSource], and the platform link is used up: what `onEnter` calls.
String? takePlatformLink(Uri uri, GoRouter router) {
  final source = platformLinkSource(uri, router);
  if (source != null) _links.clear();
  return source;
}

/// Forgets a platform link no navigation took (the router committed, or went nowhere).
void clearPlatformLink() => _links.clear();

/// Removes the binding observer and forgets everything: a test's tear down (the observer and
/// the last link are global, like the binding).
@visibleForTesting
void debugResetPlatformLinks() => _links.reset();

final _PlatformLinks _links = _PlatformLinks();

/// Records the location of the last platform link. A binding observer, not a listener on the
/// router: it only stores a `Uri`, schedules nothing and answers synchronously.
final class _PlatformLinks with WidgetsBindingObserver {
  Uri? _link;
  WidgetsBinding? _binding;

  /// True while `launchRouter` runs `make`: the router does not exist yet.
  bool making = false;

  /// Routers made by `launchRouter(links: true)`.
  final Expando<bool> _routers = Expando<bool>('fespalier platform links');

  void add(GoRouter router) => _routers[router] = true;

  void register(WidgetsBinding binding) {
    _binding?.removeObserver(this);
    binding.removeObserver(this);
    binding.addObserver(this);
    _binding = binding;
  }

  void reset() {
    _binding?.removeObserver(this);
    _binding = null;
    _link = null;
    making = false;
  }

  /// Whether [router] was made with links on (null: the one being made).
  bool linked(GoRouter? router) =>
      making || (router != null && (_routers[router] ?? false));

  void record(Uri uri) => _link = uri;

  void clear() => _link = null;

  bool matches(Uri uri) {
    final link = _link;
    if (link == null) return false;
    return _path(link) == _path(uri) && link.query == uri.query;
  }

  /// go_router's own normalisation, `RouteConfiguration.normalizeUri`: a leading `/`, no trailing
  /// one. The platform sends a full URL; go_router parses it the same way.
  static String _path(Uri uri) {
    var path = uri.path;
    if (!path.startsWith('/')) path = '/$path';
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) {
    try {
      // A link carries no state; go_router's own pushes (the browser, restoration) do.
      if (routeInformation.state == null && !inboundIsWeb) {
        _link = routeInformation.uri;
      }
    } catch (_) {
      // Instrumentation never costs a feature.
    }
    return SynchronousFuture<bool>(false);
  }
}
