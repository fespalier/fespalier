import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart' hide RouteMatch;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/link.dart' as url;

import 'devtools/devtools.dart' show devToolsAs, kFespalierDevTools;
import 'devtools/protocol.dart' show HolderKind;
import 'location.dart';
import 'route_data.dart';
import 'route_match.dart';

/// When a [RouteLink] starts loading the data, and for a deferred route the code, of the
/// page it points at.
enum Preload {
  /// Never: the page loads its data when it is reached.
  none,

  /// When the user shows intent: the pointer enters the link (hover), the link
  /// or something inside it takes focus, or a pointer goes down on it (the
  /// start of a tap). Kept until the link is disposed.
  intent,

  /// When the link is on screen: laid out inside the view and inside every
  /// scrollable around it, and not on an offstage route or tab. Released when
  /// it leaves the screen, and when the link is disposed.
  visible,
}

/// How a [RouteLink] navigates on a plain click or tap.
enum LinkMethod {
  /// `GoRouter.go`: the location becomes the whole stack, as a URL typed in the
  /// address bar would.
  go,

  /// `GoRouter.push`: the page goes on top of the current one, and back returns.
  push,

  /// `TypedLocation.replace`: the page takes the place of the current one, and on the
  /// web its location replaces the history entry (see `replaceLocation`).
  replace,
}

/// Builds the widget a [RouteLink] wraps. [follow] navigates to the link's
/// location: give it to the child's `onTap` or `onPressed`.
typedef RouteLinkBuilder =
    Widget Function(BuildContext context, VoidCallback follow);

/// The defaults of every [RouteLink] below it, set once for the app:
///
/// ```dart
/// MaterialApp.router(
///   routerConfig: router,
///   builder: (context, child) => RouteLinkScope(
///     preload: Preload.intent,
///     match: AppRoutes.matchUrl,
///     child: child!,
///   ),
/// )
/// ```
///
/// Without one, a link preloads nothing unless it says so, a `uri:` link
/// preloads nothing at all, and a `uri:` link is checked (in debug builds)
/// against the routes of the router above it.
class RouteLinkScope extends InheritedWidget {
  /// Sets [preload] and [match] for the [RouteLink]s in [child].
  const RouteLinkScope({
    super.key,
    this.preload = Preload.none,
    this.match,
    required super.child,
  });

  /// When a link that doesn't set its own `preload` preloads.
  final Preload preload;

  /// The generated `AppRoutes.matchUrl`: how a `uri:` link finds the route it
  /// points at, to preload its data and, in debug builds, to assert that one
  /// exists (a segment that doesn't parse included). Without it, a `uri:` link
  /// preloads nothing and is checked against go_router's configuration. The link
  /// preloads with the matched route's `preload`: its data and a deferred page's code.
  final UrlMatch? Function(Uri uri)? match;

  /// The nearest scope above [context], if any; [context] depends on it.
  static RouteLinkScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RouteLinkScope>();

  @override
  bool updateShouldNotify(RouteLinkScope oldWidget) =>
      preload != oldWidget.preload || match != oldWidget.match;
}

/// A link to a route of the app: a real `<a href>` on the web, a plain widget
/// elsewhere, and, either way, a click that navigates through go_router.
///
/// ```dart
/// RouteLink(
///   to: ProductRoute(id: p.id),
///   preload: Preload.intent,
///   builder: (context, follow) => ListTile(title: Text(p.name), onTap: follow),
/// )
/// ```
///
/// It is built on url_launcher's `Link`. On the web that lays an invisible
/// anchor over the child, so the browser shows the URL in its status bar, and
/// a middle click, a click with Ctrl, Cmd, Shift or Alt, and the context menu
/// open it in a new tab or window. A plain click (or `follow` called any other
/// way) goes through `GoRouter` with [method], so `push` and `replace` work
/// and the page doesn't reload. On other platforms there is no anchor, and
/// `follow` navigates the same way. The child is exposed to accessibility
/// services as a link with its URL.
///
/// [to] is a typed route; [uri] a location as a string would give it, mount
/// prefix included (`Uri.parse('/shop/products/2')`). In a debug build a [uri]
/// that matches no route throws when the link builds. A link carries no
/// `extra`: for a route that takes one, call `route.go(context, extra: ...)`
/// from the child's own `onTap`.
///
/// With [preload] the data of the page it points at loads before it is followed, and so
/// does its code when its `page.dart` is deferred (since 0.7.0, see [Preload]); nothing
/// navigates and no guard runs until it is.
class RouteLink extends ConsumerStatefulWidget {
  /// A link to [to] or [uri] (exactly one of them), built by [builder].
  const RouteLink({
    super.key,
    this.to,
    this.uri,
    this.locale,
    this.method = LinkMethod.go,
    this.preload,
    required this.builder,
  }) : assert(
         (to == null) != (uri == null),
         'RouteLink takes either `to:` (a typed route) or `uri:` (a location), '
         'and exactly one of them',
       );

  /// The typed route the link points at (`ProductRoute(id: 42)`).
  final TypedLocation? to;

  /// The location the link points at, when it isn't a typed route: a path in
  /// this app, with its query, and with the mount prefix if the routes are
  /// mounted below one. Not an external URL: use url_launcher's `Link` for
  /// those.
  final Uri? uri;

  /// Which spelling of [to]'s localized segments the link uses
  /// (`TypedLocation.locationFor`); the canonical one when null. Unused with
  /// [uri], which is spelled as given.
  final String? locale;

  /// How a plain click navigates: [LinkMethod.go] by default.
  final LinkMethod method;

  /// When the data (and the code of a deferred page) of the page it points at starts
  /// loading; null for the
  /// nearest [RouteLinkScope]'s, or [Preload.none] without one.
  final Preload? preload;

  /// Builds the child, given the callback that follows the link.
  final RouteLinkBuilder builder;

  /// The location the link points at, as it goes in the `href` and to the
  /// router: [to]'s (in [locale]'s spelling) or [uri].
  String get location => to?.locationFor(locale) ?? uri.toString();

  @override
  ConsumerState<RouteLink> createState() => _RouteLinkState();
}

class _RouteLinkState extends ConsumerState<RouteLink> {
  late String _location = widget.location;
  late Uri _uri = Uri.parse(_location);

  /// What the held handle was started for: dropped when either changes.
  (String, Preload)? _startedFor;
  PrefetchHandle? _handle;

  RouteLinkScope? _scope;
  bool _tickerEnabled = true;
  Size? _viewSize;
  final List<(ScrollableState, ScrollPosition)> _scrollables = [];
  bool _checkScheduled = false;

  /// What the debug check last looked at, so it runs once per change.
  Object? _checked;

  Preload get _preload => widget.preload ?? _scope?.preload ?? Preload.none;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = RouteLinkScope.maybeOf(context);
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _viewSize = MediaQuery.maybeSizeOf(context);
    _listenToScrollables();
    _dropStaleHandle();
    _scheduleVisibilityCheck();
  }

  @override
  void didUpdateWidget(RouteLink oldWidget) {
    super.didUpdateWidget(oldWidget);
    final location = widget.location;
    if (location != _location) {
      _location = location;
      _uri = Uri.parse(location);
    }
    if (oldWidget.preload != widget.preload) _listenToScrollables();
    _dropStaleHandle();
  }

  @override
  void dispose() {
    _forgetScrollables();
    _release();
    super.dispose();
  }

  /// Releases what was preloaded for another location or another mode.
  void _dropStaleHandle() {
    final started = _startedFor;
    if (started != null && started != (_location, _preload)) _release();
  }

  /// Listens to the position of every scrollable around the link, nearest
  /// first, so scrolling any of them checks whether it is still visible.
  void _listenToScrollables() {
    _forgetScrollables();
    if (_preload != Preload.visible) return;
    // The nearest one is a dependency: a new position (a new controller) is seen.
    var scrollable = Scrollable.maybeOf(context);
    while (scrollable != null) {
      final position = scrollable.position
        ..addListener(_scheduleVisibilityCheck);
      _scrollables.add((scrollable, position));
      scrollable = scrollable.context
          .findAncestorStateOfType<ScrollableState>();
    }
  }

  void _forgetScrollables() {
    for (final (_, position) in _scrollables) {
      position.removeListener(_scheduleVisibilityCheck);
    }
    _scrollables.clear();
  }

  void _scheduleVisibilityCheck() {
    if (_checkScheduled || !mounted || _preload != Preload.visible) return;
    _checkScheduled = true;
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted || _preload != Preload.visible) return;
      if (_isVisible()) {
        _start();
      } else {
        _release();
      }
    });
    // A scroll between frames: the callback needs one to run in.
    if (binding.schedulerPhase == SchedulerPhase.idle) {
      binding.ensureVisualUpdate();
    }
  }

  /// Whether some of the link is on screen: inside the view and the viewport of
  /// every scrollable around it, on a route or tab that is not offstage.
  bool _isVisible() {
    if (!_tickerEnabled) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    var rect = _globalRect(box);
    final view = _viewSize;
    if (view != null) rect = rect.intersect(Offset.zero & view);
    for (final (scrollable, _) in _scrollables) {
      final viewport = scrollable.context.findRenderObject();
      if (viewport is RenderBox && viewport.attached && viewport.hasSize) {
        rect = rect.intersect(_globalRect(viewport));
      }
    }
    return !rect.isEmpty;
  }

  static Rect _globalRect(RenderBox box) => MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );

  void _onIntent() {
    if (_preload == Preload.intent) _start(retry: true);
  }

  /// Starts preloading, unless a preload is already held. A load that failed
  /// closed its handle: it is started again only when [retry] says the user
  /// asked for it again (intent), not on every scroll tick (visible).
  void _start({bool retry = false}) {
    final held = _handle;
    if (held != null && !(retry && held.isClosed)) return;
    final to = widget.to;
    if (to != null) {
      _handle = kFespalierDevTools
          ? devToolsAs(HolderKind.link, () => to.preload(ref))
          : to.preload(ref);
    } else {
      final match = _scope?.match?.call(widget.uri!);
      if (match == null) return;
      _handle = kFespalierDevTools
          ? devToolsAs(HolderKind.link, () => match.route.preload(ref))
          : match.route.preload(ref);
    }
    _startedFor = (_location, _preload);
  }

  void _release() {
    _handle?.close();
    _handle = null;
    _startedFor = null;
  }

  void _follow(url.FollowLink? followLink) {
    // On the web a click with a modifier is the browser's: handing the click to
    // url_launcher lets the anchor open the link in a new tab or window. A plain
    // one never reaches it, so the anchor's own navigation is cancelled and
    // go_router does the work.
    if (kIsWeb && followLink != null && _opensElsewhere) {
      unawaited(followLink());
      return;
    }
    final router = GoRouter.of(context);
    switch (widget.method) {
      case LinkMethod.go:
        router.go(_location);
      case LinkMethod.push:
        unawaited(router.push<Object?>(_location));
      case LinkMethod.replace:
        replaceLocation(context, _location);
    }
  }

  static bool get _opensElsewhere {
    final keys = HardwareKeyboard.instance;
    return keys.isControlPressed ||
        keys.isMetaPressed ||
        keys.isShiftPressed ||
        keys.isAltPressed;
  }

  @override
  Widget build(BuildContext context) {
    assert(_debugCheckUri(context));
    _scheduleVisibilityCheck();
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _onIntent(),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onFocusChange: (focused) {
          if (focused) _onIntent();
        },
        child: Listener(
          onPointerDown: (_) => _onIntent(),
          child: url.Link(
            uri: _uri,
            builder: (context, followLink) {
              final child = widget.builder(context, () => _follow(followLink));
              // On the web the anchor's delegate already says "link"; elsewhere
              // nothing does.
              if (kIsWeb) return child;
              return MergeSemantics(
                child: Semantics(link: true, linkUrl: _uri, child: child),
              );
            },
          ),
        ),
      ),
    );
  }

  /// In debug builds: a `uri:` link must point at a route of the app.
  bool _debugCheckUri(BuildContext context) {
    final uri = widget.uri;
    if (uri == null) return true;
    if (uri.hasScheme || uri.hasAuthority) {
      throw FlutterError.fromParts([
        ErrorSummary('RouteLink(uri: $uri) is not a location in this app.'),
        ErrorHint(
          "A RouteLink navigates with go_router; for another site, use "
          "url_launcher's Link.",
        ),
      ]);
    }
    final match = _scope?.match;
    final router = match == null ? GoRouter.maybeOf(context) : null;
    if (match == null && router == null) return true;
    // Once per location and per source of truth, not on every build.
    final checking = Object.hash(uri, match, router);
    if (_checked == checking) return true;
    final found = match != null
        ? match(uri) != null
        : !router!.configuration.findMatch(uri).isError;
    if (!found) {
      final how = match != null
          ? "RouteLinkScope.match found no route for it, or a segment of it "
                "doesn't parse"
          : 'no route of the GoRouter above it matches it';
      throw FlutterError.fromParts([
        ErrorSummary('RouteLink(uri: $uri) points at no route of this app.'),
        ErrorDescription('$how, so following it would show not_found.dart.'),
        ErrorHint(
          'Fix the location (it includes the mount prefix, if the routes are '
          'mounted below one), or link to a typed route with `to:`.',
        ),
      ]);
    }
    _checked = checking;
    return true;
  }
}
