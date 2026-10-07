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
/// With [launch], [make] is expected to start the router at `launch.location`
/// (`overridePlatformDefaultLocation`), over the platform's initial route, and the first navigation
/// is marked with `launch.source`. Without one, a platform deep link at cold start is marked
/// `NavigationSource.link` when [links] is set (an app with telemetry or adapters), and so is each
/// platform link the running app receives afterwards. Never on the web. [make] runs once,
/// synchronously, and what it builds is returned. With [links] off, no listener is added.
GoRouter launchRouter(
  InboundLaunch? launch,
  GoRouter Function() make, {
  bool links = false,
}) {
  assert(
    launch == null || !inboundIsWeb,
    'launchRouter: a launch is not used on the web (the address bar is the '
    'launch); FespalierAdapters.launch() answers null there',
  );
  if (inboundIsWeb) return make();
  if (launch != null) return navigateFrom(launch.source, make);
  if (!links) return make();
  final binding = WidgetsBinding.instance;
  // Before make(): go_router's provider registers itself with the binding on its first listener,
  // and a binding observer added first hears a platform link first.
  _links.register(binding);
  final platform = Uri.parse(binding.platformDispatcher.defaultRouteName);
  if (platform.path.isEmpty || (platform.path == '/' && !platform.hasQuery)) {
    return make();
  }
  _links.record(platform);
  return navigateFrom(NavigationSource.link, make);
}

/// `NavigationSource.link` when the platform handed the router [uri] and nothing consumed it yet
/// (a peek: telemetry's navigation start asks, then `onEnter`); null otherwise.
String? platformLinkSource(Uri uri) =>
    _links.matches(uri) ? NavigationSource.link : null;

/// Like [platformLinkSource], and the platform link is used up: what `onEnter` calls.
String? takePlatformLink(Uri uri) {
  final source = platformLinkSource(uri);
  if (source != null) _links.clear();
  return source;
}

/// Forgets a platform link no navigation took (the router committed, or went nowhere).
void clearPlatformLink() => _links.clear();

final _PlatformLinks _links = _PlatformLinks();

/// Records the location of the last platform link. A binding observer, not a listener on the
/// router: it only stores a `Uri`, schedules nothing and answers synchronously.
final class _PlatformLinks with WidgetsBindingObserver {
  Uri? _link;

  void register(WidgetsBinding binding) {
    binding.removeObserver(this);
    binding.addObserver(this);
  }

  void record(Uri uri) => _link = uri;

  void clear() => _link = null;

  bool matches(Uri uri) {
    final link = _link;
    if (link == null) return false;
    String path(Uri u) => u.path.isEmpty ? '/' : u.path;
    return path(link) == path(uri) && link.query == uri.query;
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
