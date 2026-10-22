/// Route lifecycle (since 0.8.1): the `observe.dart` hooks, run when a page becomes the one the
/// user sees, is the one on top again, and is gone.
///
/// One watch per router diffs the router's committed configuration at the end of the first
/// frame that shows a change (a post-frame callback, never during build). It is the only thing
/// here that runs: it creates no `Future`, no microtask and no timer, and it schedules no frame
/// of its own (the delegate's notification already makes the `Router` rebuild, which does).
/// Telemetry (`telemetry.dart`) reads the same diff, so the two can never disagree about what
/// a page event is. Since 0.19.0 telemetry also hears each commit as it happens, before the frame
/// that builds its page.
library;

import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show BuildContext, ErrorDescription;
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'guards.dart'
    show GuardFailure, guardBeforeRerun, isGuardRerun, refusedEntry;
import 'inbound.dart' show clearPlatformLink, platformLinkSource;
import 'navigation_kind.dart';
import 'route_info.dart' show pathTemplate;
import 'route_scope.dart';
import 'telemetry.dart';

/// The hooks of one `observe.dart` for one page: what a generated `app.g.dart` builds for the
/// route at a location. [file] names the observe.dart (relative to the app folder) in error
/// reports.
final class RouteHooks {
  /// Hooks of [file]; each takes the one-off `Ref` it runs in.
  const RouteHooks(this.file, {this.onEnter, this.onLeave, this.onFocus});

  /// The observe.dart these hooks come from, relative to the app folder.
  final String file;

  /// `onEnter`: the page became the visible one for the first time. [RouteScope] is the page
  /// instance's scope (since 0.11.0), shared by every observe.dart of the page.
  final void Function(Ref ref, RouteScope scope)? onEnter;

  /// `onLeave`: the page is gone.
  final void Function(Ref ref)? onLeave;

  /// `onFocus`: the page is the visible one again.
  final void Function(Ref ref)? onFocus;
}

/// Runs the observe.dart hooks of the pages [router] shows. The generated `AppRoutes.attach`
/// calls it; [hooksAt] is the generated `_observeAt` (the hooks of the route at a location,
/// outermost first, or empty). Attaching the same router twice does nothing new.
///
/// Hooks run at the end of the first frame that shows the change, so a widget test pumps
/// before it looks at what they did. The router's own notifiers are all there is to clean up,
/// and they go with the router.
///
/// Hooks run in [container] when it is given (since 0.11.0: the generated
/// `AppRoutes.attach(router, container)` passes the app's), else in the container found above
/// the root navigator.
void observeAttach(
  GoRouter router,
  List<RouteHooks> Function(Uri uri) hooksAt, {
  ProviderContainer? container,
}) {
  final watch = RouterWatch.of(router)..hooksAt = hooksAt;
  if (container != null) watch.container = container;
  watch.scheduleFirst();
}

Duration? _noRetry(int retryCount, Object error) => null;

/// One page instance on a navigator, as the diff sees it.
final class _Instance {
  _Instance(this.id, this.uri, this.fullPath, this.branches);

  /// `'<pageKey>#<matchedLocation>'` for a page whose key is a route's path template (a tree
  /// page, and also a page `replace` put in its place: `replace` keeps the replaced page's key),
  /// `'<pageKey>@<path>'` for a page with a random key (`push`, `pushReplacement`). See
  /// `instanceId`.
  final String id;

  /// Where the page is, query included.
  final Uri uri;

  /// go_router's path template of the page, mount point included; null for an error page.
  final String? fullPath;

  /// The tab branches the page sits in, outermost first: `shell key|navigator key`, with the
  /// shell's key alone ahead of the `|`.
  final List<String> branches;
}

/// What one walk of the committed configuration found.
final class _Walk {
  /// The walk of [router], when a pushed page of it can be held back (since 0.21.0).
  _Walk([this.router]);

  final GoRouter? router;

  final List<_Instance> instances = [];

  /// Whether the last thing the walk found is the error view of a pushed navigation that failed
  /// its guard (since 0.21.0): it covers [instances], and the page under it is not the visible one.
  bool covered = false;

  /// The tab branches that are the current one of their shell.
  final Set<String> activeBranches = {};

  /// The tab shells on screen.
  final Set<String> liveShells = {};

  Set<String> get ids => {for (final i in instances) i.id};

  void add(List<RouteMatchBase> matches, Uri uri, List<String> branches) {
    for (final m in matches) {
      if (m is ImperativeRouteMatch) {
        // A pushed navigation that failed its guard (since 0.21.0): go_router keeps the failed list
        // here, with an empty path, and the page it was pushed from stays under its error view. It
        // is no page, but it covers the one below: that page is not visible until the view closes.
        // A pushed page whose guard has not passed (a restored one, fespalier/fespalier#258) is held
        // back the same way.
        final r = router;
        if (m.matches.isError || (r != null && refusedEntry(r, m))) {
          covered = true;
          continue;
        }
        covered = false;
        instances.add(
          _Instance(
            instanceId(m.pageKey.value, m.matchedLocation, m.matches.uri.path),
            m.matches.uri,
            m.matches.fullPath,
            branches,
          ),
        );
      } else if (m is ShellRouteMatch) {
        if (m.route is StatefulShellRoute) {
          final shell = m.pageKey.value;
          final branch = '$shell|${identityHashCode(m.navigatorKey)}';
          liveShells.add(shell);
          activeBranches.add(branch);
          add(m.matches, uri, [...branches, branch]);
        } else {
          add(m.matches, uri, branches);
        }
      } else if (m is RouteMatch) {
        covered = false;
        instances.add(
          _Instance(
            instanceId(m.pageKey.value, m.matchedLocation, uri.path),
            uri,
            m.pageKey.value,
            branches,
          ),
        );
      }
    }
  }
}

/// What `_top` is while the error view of a pushed navigation covers the page below: no page has
/// this id, so the page below is on top again, and gets its focus, once the view closes.
const _coveredTop = '<error view>';

/// A page instance the hooks have seen enter.
final class _Entered {
  _Entered(this.instance, this.hooks, this.pattern);

  final _Instance instance;

  /// The hooks as they were bound when the page entered: `onLeave` gets the parameters the
  /// page entered with.
  final List<RouteHooks> hooks;

  /// The page's pattern, for telemetry.
  final String? pattern;

  /// When the page entered, for telemetry's `fespalier.page.duration_ms`.
  final Stopwatch watch = Stopwatch()..start();

  /// The page's scope: a plain object made when an `onEnter` of the page first runs (the
  /// generated closures all take one), with no subscription until a hook calls `hold`; ended
  /// when the page leaves.
  RouteScopeImpl? scope;
}

/// A navigation telemetry is following: from the request (or the commit that had none) to the
/// end of the first frame after the commit.
final class _Nav {
  _Nav(this.token, this.requested);

  /// What the sink returned for the start.
  final Object? token;

  /// The location asked for; null for a navigation that starts at its commit (a pop, a guard's
  /// refresh).
  final Uri? requested;

  bool committed = false;
  String? kind;
  int depth = 0;
}

/// The one watch on a router that the lifecycle hooks and telemetry share. Not exported: the
/// public entry points are [observeAttach] and `telemetryAttach`.
final class RouterWatch {
  RouterWatch._(this.router) {
    router.routerDelegate.addListener(_committed);
    guardBeforeRerun[router] = _flush;
  }

  static final Expando<RouterWatch> _watches = Expando<RouterWatch>(
    'fespalier lifecycle',
  );

  /// The watch on [router], made on first use.
  static RouterWatch of(GoRouter router) =>
      _watches[router] ??= RouterWatch._(router);

  /// The watch on [router] when something made one, else null: it makes none.
  static RouterWatch? peek(GoRouter router) => _watches[router];

  /// The router being watched.
  final GoRouter router;

  /// The generated `_observeAt`, once `observeAttach` was called.
  List<RouteHooks> Function(Uri uri)? hooksAt;

  /// The app's container, when `observeAttach` was given one.
  ProviderContainer? container;

  /// The post-frame callback that runs [_diff] is waiting for the end of the frame: the number of
  /// that callback, null when none is. A [_flush] runs the diff before its callback does, and the
  /// callback then finds another number, or none.
  int? _pending;
  int _callbacks = 0;
  final Map<String, _Entered> _entered = {};
  String? _top;

  // Telemetry: set by `enableTelemetry`.
  bool _telemetry = false;

  /// Whether `enableTelemetry` ran: the router's navigations and page events reach the sink.
  bool get followsTelemetry => _telemetry;
  String Function()? _base;
  _Nav? _nav;
  NavSnapshot? _snapshot;
  String? _topPattern;

  /// Looks at a router that already has a location when it is attached.
  void scheduleFirst() {
    if (router.routerDelegate.currentConfiguration.isNotEmpty) _schedule();
  }

  /// Makes the watch report navigations and page events to the installed
  /// [FespalierTelemetry] sink. [base] returns where the tree is mounted.
  void enableTelemetry(String Function() base) {
    _base = base;
    if (_telemetry) return;
    _telemetry = true;
    // Kept until the router is disposed, and nothing else removes it. go_router registers its
    // provider as a platform observer while the provider has a listener, so a router the app
    // replaced without disposing it keeps answering platform links (#264, docs/observability.md).
    // Nothing says when the Router lets go of the provider or takes it back. The end of a frame in
    // which another watched router commits shows that a router is off screen, but nothing shows it
    // coming back where it was, so taking its provider off there would break a swap back. A fix
    // needs that signal.
    router.routeInformationProvider.addListener(_requested);
    final config = router.routerDelegate.currentConfiguration;
    if (config.isEmpty && config.error == null) {
      // Not parsed yet: this is the initial navigation, and it starts now.
      if (telemetryOn) {
        final uri = router.routeInformationProvider.value.uri;
        _nav = _Nav(telemetryNavigationStart(uri, source: _sourceOf(uri)), uri);
      }
    } else {
      // Attached late: the router already shows its first location.
      final (:kind, :now) = classifyNavigation(config, null);
      _snapshot = now;
      if (telemetryOn) {
        final nav = _Nav(telemetryNavigationStart(null), null)
          ..committed = true
          ..kind = kind
          ..depth = now.depth;
        _nav = nav;
        // A throw in the walk, `pathTemplate` or the app's `base` costs the commit, not the
        // frame callback below.
        try {
          _tellCommit(nav, config);
        } catch (e) {
          telemetryAttachError(e);
        }
      }
      _schedule();
    }
  }

  /// The route information provider notified: a location was requested (`go`, `push`,
  /// `replace`, a tab switch, the platform), or the router was refreshed.
  void _requested() {
    try {
      if (!telemetryOn) return;
      // A guard's re-run of a pushed page (since 0.21.0) is no navigation of the app's, and no
      // request: it starts at its commit with nothing requested, as a guard's refresh does.
      if (isGuardRerun(router, router.routeInformationProvider.value.state)) {
        return;
      }
      final uri = router.routeInformationProvider.value.uri;
      // The same location as the one committed: `GoRouter.refresh()` only notifies again, and a
      // `go` to where you are commits nothing. Not a new navigation.
      if (uri == router.routerDelegate.currentConfiguration.uri) {
        clearPlatformLink();
        return;
      }
      _endPending();
      _nav = _Nav(telemetryNavigationStart(uri, source: _sourceOf(uri)), uri);
    } catch (e) {
      telemetryAttachError(e);
    }
  }

  /// A navigation is in the way of a newer one: one that never committed is superseded, and
  /// one that did is ended with what it committed.
  void _endPending() {
    final nav = _nav;
    if (nav == null) return;
    _nav = null;
    if (!nav.committed) {
      telemetryNavigationEnd(
        nav.token,
        const TelemetryEnd(TelemetryOutcome.superseded),
      );
      return;
    }
    final config = router.routerDelegate.currentConfiguration;
    final walk = _Walk(router)..add(config.matches, config.uri, const []);
    _endNavigation(nav, config, walk.instances.lastOrNull);
  }

  /// What marks a navigation to [uri]: `navigateFrom`'s source, else `link` for a platform link
  /// (since 0.11.0; a peek, `onEnter` uses the link up, and the commit forgets it).
  String? _sourceOf(Uri uri) =>
      takeNavigationSource() ?? platformLinkSource(uri, router);

  void _committed() {
    clearPlatformLink();
    if (_telemetry) _committedForTelemetry();
    _schedule();
  }

  void _committedForTelemetry() {
    try {
      final config = router.routerDelegate.currentConfiguration;
      if (config.isEmpty && config.error == null) return;
      final (:kind, :now) = classifyNavigation(config, _snapshot);
      _snapshot = now;
      if (!telemetryOn) return;
      // A commit nobody asked for (a pop, a guard's refresh) starts its navigation here.
      final nav = _nav ??= _Nav(telemetryNavigationStart(null), null);
      // A second commit before the frame (a refresh) keeps the kind of the first.
      if (!nav.committed) nav.kind = kind;
      nav.committed = true;
      nav.depth = now.depth;
      _tellCommit(nav, config);
    } catch (e) {
      telemetryAttachError(e);
    }
  }

  void _schedule() {
    if (_pending != null) return;
    final callback = _pending = ++_callbacks;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_pending == callback) _diff();
    });
  }

  /// Runs the diff of the commits that wait for the end of the frame now (since 0.21.1), as a
  /// guard's re-run is about to replace the page the last commit shows. Whoever reads a commit
  /// first registers its post-frame callbacks first: DevTools and telemetry read it as it happens,
  /// the guards' judgment of it registers the re-run's, and the watch's own callback, registered
  /// after, would run after a synchronous re-run had landed. The diff would then see the page that
  /// was held (an empty box in the frame that was just built) already passed and show, and report
  /// nothing: neither the `onLeave` of the page that was gone for that frame nor the `onEnter` of
  /// the page made again. Run first, the diff of a commit sees what the frame showed, in every order.
  void _flush() {
    if (_pending != null) _diff();
  }

  void _diff() {
    _pending = null;
    final RouteMatchList config;
    final _Walk walk;
    try {
      config = router.routerDelegate.currentConfiguration;
      if (config.isEmpty && config.error == null) return;
      walk = _Walk(router)..add(config.matches, config.uri, const []);
    } catch (_) {
      return;
    }
    final present = walk.ids;
    bool parked(_Entered e) {
      final b = e.instance.branches;
      return b.isNotEmpty &&
          b.every((k) => walk.liveShells.contains(k.split('|').first)) &&
          b.any((k) => !walk.activeBranches.contains(k));
    }

    final pages = <TelemetryPage>[];
    // Leave: every entered page that is on no navigator any more, newest first.
    for (final e in _entered.values.toList().reversed) {
      if (present.contains(e.instance.id) || parked(e)) continue;
      _entered.remove(e.instance.id);
      if (_telemetry) {
        pages.add(
          TelemetryPage(
            TelemetryPageKind.leave,
            e.pattern,
            duration: e.watch.elapsed,
          ),
        );
      }
      _run(e.hooks.reversed, 'onLeave', (h) => h.onLeave);
      try {
        e.scope?.end();
      } catch (error, st) {
        _report(error, st, 'while ending the RouteScope of ${e.instance.id}');
      }
    }
    // Then the page on top: entered for the first time, or on top again. Under the error view of a
    // pushed navigation that failed its guard (since 0.21.0) it is neither: the view has no hooks
    // and covers the page below, which gets its `onFocus` when the view closes, not before.
    final visible = walk.instances.lastOrNull;
    if (visible != null && !walk.covered) {
      final known = _entered[visible.id];
      final pattern = _telemetry ? _patternOf(visible) : null;
      if (known == null) {
        final hooks = _bind(visible.uri);
        _entered[visible.id] = _Entered(visible, hooks, pattern);
        if (_telemetry) {
          pages.add(TelemetryPage(TelemetryPageKind.enter, pattern));
        }
        final entered = _entered[visible.id]!;
        _run(hooks, 'onEnter', (h) {
          final hook = h.onEnter;
          if (hook == null) return null;
          return (ref) => hook(ref, entered.scope ??= _scopeFor(visible));
        });
      } else if (_top != visible.id) {
        if (_telemetry) {
          pages.add(TelemetryPage(TelemetryPageKind.focus, pattern));
        }
        _run(_bind(visible.uri), 'onFocus', (h) => h.onFocus);
      }
    }
    _top = walk.covered ? _coveredTop : visible?.id;
    if (_telemetry) _finishTelemetry(config, visible, pages);
  }

  RouteScopeImpl _scopeFor(_Instance i) {
    final container =
        this.container ??
        ProviderScope.containerOf(
          router.routerDelegate.navigatorKey.currentContext!,
          listen: false,
        );
    return RouteScopeImpl(i.id, i.uri, container);
  }

  String? _patternOf(_Instance i) =>
      pathTemplate(i.fullPath, _base?.call() ?? '/');

  /// The list that tells what [config] shows on top (since 0.21.0): [config] itself, or, when a page
  /// was pushed (`push`, `pushReplacement`, `replace`), the list of the page on top. go_router keeps
  /// the error of a pushed navigation there and not in [config], whose own `error` stays null.
  RouteMatchList _activeOf(RouteMatchList config) {
    final pushed = <ImperativeRouteMatch>[];
    pushedMatches(config.matches, pushed);
    return activeMatches(config, pushed);
  }

  /// The pattern of the page [config] shows ([visible] is the top of its walk), null when the router
  /// shows its error route, as its own or over a pushed navigation: what a navigation's commit and
  /// its end both report, so the two never differ.
  String? _routeOf(RouteMatchList config, _Instance? visible) =>
      _isErrorView(config) || visible == null ? null : _patternOf(visible);

  /// Whether the router shows an error view for [config] (since 0.21.0): its own error, the failed
  /// list of a pushed navigation, or a held pushed page (whose guard has not passed: its page is not
  /// built, see `refusedView`).
  bool _isErrorView(RouteMatchList config) {
    if (_activeOf(config).isError) return true;
    final pushed = <ImperativeRouteMatch>[];
    pushedMatches(config.matches, pushed);
    return pushed.isNotEmpty && refusedEntry(router, pushed.last);
  }

  /// What [config] says of its navigation (since 0.21.0): `error` when a guard or a `redirect.dart`
  /// failed and the router shows the error view ([GuardFailure]), `not_found` for any other error of
  /// the router's (no route matched, a redirect loop), `ok` otherwise. A navigation that was pushed
  /// says it the same way, though go_router holds its error in the pushed entry.
  String _outcomeOf(RouteMatchList config) {
    if (_isErrorView(config) && _activeOf(config).error == null) {
      // A held pushed page (since 0.21.0) is the error view of its navigation until its guard passes.
      return TelemetryOutcome.error;
    }
    return switch (_activeOf(config).error) {
      null => TelemetryOutcome.ok,
      GuardFailure() => TelemetryOutcome.error,
      _ => TelemetryOutcome.notFound,
    };
  }

  /// Tells the sink what [config] puts on screen, for [nav], at the commit (since 0.19.0).
  void _tellCommit(_Nav nav, RouteMatchList config) {
    final walk = _Walk(router)..add(config.matches, config.uri, const []);
    telemetryNavigationCommit(
      nav.token,
      TelemetryCommit(
        _outcomeOf(config),
        route: _routeOf(config, walk.instances.lastOrNull),
      ),
    );
  }

  /// The first frame after a commit is built: the page events, then the end of the navigation.
  void _finishTelemetry(
    RouteMatchList config,
    _Instance? visible,
    List<TelemetryPage> pages,
  ) {
    try {
      final nav = _nav;
      if (nav == null || !nav.committed) return;
      for (final page in pages) {
        telemetryPageEvent(nav.token, page);
      }
      _nav = null;
      _endNavigation(nav, config, visible);
    } catch (e) {
      telemetryAttachError(e);
    }
  }

  void _endNavigation(_Nav nav, RouteMatchList config, _Instance? visible) {
    final route = _routeOf(config, visible);
    final active = _activeOf(config);
    // An error view is at the location that failed, and so is a held pushed page (since 0.21.0):
    // the walk shows the page under it, which is not where the navigation ended.
    final location = _isErrorView(config)
        ? active.uri
        : (visible?.uri ?? config.uri);
    final requested = nav.requested;
    telemetryNavigationEnd(
      nav.token,
      TelemetryEnd(
        _outcomeOf(config),
        route: route,
        from: _topPattern,
        kind: nav.kind,
        location: location.toString(),
        redirected: requested != null && requested.path != location.path,
        depth: nav.depth,
      ),
    );
    // The next navigation comes from the page the walk shows: for the error view of a pushed
    // navigation, the page under it (`route` is null there, as for any error).
    _topPattern = config.isError || visible == null
        ? null
        : _patternOf(visible);
  }

  List<RouteHooks> _bind(Uri uri) {
    final at = hooksAt;
    if (at == null) return const [];
    try {
      return at(uri);
    } catch (e, st) {
      _report(e, st, 'while finding the observe.dart hooks of $uri');
      return const [];
    }
  }

  /// Runs [pick] of each of [hooks] in the one-off `Ref` of its own. A hook that throws is
  /// reported, and the next one still runs.
  void _run(
    Iterable<RouteHooks> hooks,
    String name,
    void Function(Ref ref)? Function(RouteHooks) pick,
  ) {
    for (final h in hooks) {
      final hook = pick(h);
      if (hook == null) continue;
      final BuildContext? context =
          router.routerDelegate.navigatorKey.currentContext;
      if (context == null) return;
      try {
        final container =
            this.container ?? ProviderScope.containerOf(context, listen: false);
        // The hook gets the `Ref` of a throwaway provider, but runs once that provider is
        // built: Riverpod forbids changing another provider while one is being built, and a
        // hook that notifies a notifier (`ref.read(views.notifier).add(...)`) must be able to.
        Ref? captured;
        final sub = container.listen<void>(
          Provider.autoDispose<void>((ref) => captured = ref, retry: _noRetry),
          (_, _) {},
        );
        try {
          sub.read();
          final ref = captured;
          if (ref != null) hook(ref);
        } finally {
          sub.close();
        }
      } catch (e, st) {
        _report(e, st, 'while running $name of ${h.file}');
      }
    }
  }
}

void _report(Object error, StackTrace stack, String what) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'fespalier',
      context: ErrorDescription(what),
    ),
  );
}
