/// Route lifecycle (since 0.8.0): the `observe.dart` hooks, run when a page becomes the one the
/// user sees, is the one on top again, and is gone.
///
/// One watch per router diffs the router's committed configuration at the end of the first
/// frame that shows a change (a post-frame callback, never during build). It is the only thing
/// here that runs: it creates no `Future`, no microtask and no timer, and it schedules no frame
/// of its own (the delegate's notification already makes the `Router` rebuild, which does).
/// Telemetry (`telemetry.dart`) reads the same diff, so the two can never disagree about what
/// a page event is.
library;

import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show BuildContext, ErrorDescription;
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The hooks of one `observe.dart` for one page: what a generated `app.g.dart` builds for the
/// route at a location. [file] names the observe.dart (relative to the app folder) in error
/// reports.
final class RouteHooks {
  /// Hooks of [file]; each takes the one-off `Ref` it runs in.
  const RouteHooks(this.file, {this.onEnter, this.onLeave, this.onFocus});

  /// The observe.dart these hooks come from, relative to the app folder.
  final String file;

  /// `onEnter`: the page became the visible one for the first time.
  final void Function(Ref ref)? onEnter;

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
void observeAttach(
  GoRouter router,
  List<RouteHooks> Function(Uri uri) hooksAt,
) {
  final watch = RouterWatch.of(router)..hooksAt = hooksAt;
  watch.scheduleFirst();
}

Duration? _noRetry(int retryCount, Object error) => null;

/// One page instance on a navigator, as the diff sees it.
final class _Instance {
  _Instance(this.id, this.uri, this.fullPath, this.branches);

  /// A tree page: go_router's page key and its matched location; a pushed page: its own page
  /// key and the path it shows.
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
  final List<_Instance> instances = [];

  /// The tab branches that are the current one of their shell.
  final Set<String> activeBranches = {};

  /// The tab shells on screen.
  final Set<String> liveShells = {};

  Set<String> get ids => {for (final i in instances) i.id};

  void add(List<RouteMatchBase> matches, Uri uri, List<String> branches) {
    for (final m in matches) {
      if (m is ImperativeRouteMatch) {
        instances.add(
          _Instance(
            '${m.pageKey.value}@${m.matches.uri.path}',
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
        instances.add(
          _Instance(
            '${m.pageKey.value}#${m.matchedLocation}',
            uri,
            m.pageKey.value,
            branches,
          ),
        );
      }
    }
  }
}

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
}

/// The one watch on a router that the lifecycle hooks and telemetry share. Not exported: the
/// public entry points are [observeAttach] and `telemetryAttach`.
final class RouterWatch {
  RouterWatch._(this.router) {
    router.routerDelegate.addListener(_committed);
  }

  static final Expando<RouterWatch> _watches = Expando<RouterWatch>(
    'fespalier lifecycle',
  );

  /// The watch on [router], made on first use.
  static RouterWatch of(GoRouter router) =>
      _watches[router] ??= RouterWatch._(router);

  /// The router being watched.
  final GoRouter router;

  /// The generated `_observeAt`, once `observeAttach` was called.
  List<RouteHooks> Function(Uri uri)? hooksAt;

  bool _pending = false;
  final Map<String, _Entered> _entered = {};
  String? _top;

  /// Looks at a router that already has a location when it is attached.
  void scheduleFirst() {
    if (router.routerDelegate.currentConfiguration.isNotEmpty) _schedule();
  }

  void _committed() => _schedule();

  void _schedule() {
    if (_pending) return;
    _pending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _diff());
  }

  void _diff() {
    _pending = false;
    final RouteMatchList config;
    final _Walk walk;
    try {
      config = router.routerDelegate.currentConfiguration;
      if (config.isEmpty && config.error == null) return;
      walk = _Walk()..add(config.matches, config.uri, const []);
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

    // Leave: every entered page that is on no navigator any more, newest first.
    for (final e in _entered.values.toList().reversed) {
      if (present.contains(e.instance.id) || parked(e)) continue;
      _entered.remove(e.instance.id);
      _run(e.hooks.reversed, 'onLeave', (h) => h.onLeave);
    }
    // Then the page on top: entered for the first time, or on top again.
    final visible = walk.instances.isEmpty ? null : walk.instances.last;
    if (visible != null) {
      final known = _entered[visible.id];
      if (known == null) {
        final hooks = _bind(visible.uri);
        _entered[visible.id] = _Entered(visible, hooks, null);
        _run(hooks, 'onEnter', (h) => h.onEnter);
      } else if (_top != visible.id) {
        _run(_bind(visible.uri), 'onFocus', (h) => h.onFocus);
      }
    }
    _top = visible?.id;
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
        final container = ProviderScope.containerOf(context, listen: false);
        final sub = container.listen<void>(
          Provider.autoDispose<void>(hook, retry: _noRetry),
          (_, _) {},
        );
        try {
          sub.read();
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
