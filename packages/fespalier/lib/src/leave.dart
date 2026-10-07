/// `leave.dart` (since 0.11.0): asked before a page goes.
///
/// A folder's `leave()` becomes the `onExit` of its `GoRoute`, and its page is wrapped in
/// [leaveScope], which holds the page's [LeaveSource]s (a form with unsaved changes) and a
/// `PopScope`, so the back gestures ask too. See docs/navigation.md, "Leaving a page:
/// `leave.dart`".
///
/// Nothing here starts a timer or a listener of its own, and a synchronous answer stays
/// synchronous: [leaveExit] makes no `Future` and no microtask for a `leave()` that returns a
/// `bool`.
library;

import 'dart:async';

import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'lifecycle.dart' show RouterWatch;
import 'route_scope.dart' show pageInstanceId;
import 'segments.dart' show BadSegment;

/// What a `leave()` returns (since 0.11.0): `true` lets the page go, `false` keeps it. The twin
/// of `GuardResult`, so a `leave.dart` needs no `dart:async`.
typedef LeaveResult = FutureOr<bool>;

/// What `leave()` learns about the page that is going (since 0.11.0): the state of its route
/// and what the page's [LeaveSource]s say, a form with unsaved changes being the usual one.
///
/// ```dart
/// LeaveResult leave(BuildContext context, Ref ref, {required PageLeave page}) async {
///   if (!page.isDirty) return true; // a bool returned directly stays synchronous
///   return await askToDiscard(context) ?? false;
/// }
/// ```
final class PageLeave {
  /// What `leaveExit` hands to `leave()`: [state] is the route's, [sources] are what the page
  /// registered in its [LeaveScope] (none for a page that has nothing to ask about).
  PageLeave(this.state, [Iterable<LeaveSource> sources = const []])
    : _sources = List<LeaveSource>.unmodifiable(sources);

  /// The state of the route that is going.
  final GoRouterState state;

  final List<LeaveSource> _sources;

  /// Whether any registered source is dirty: it holds input that would be lost.
  bool get isDirty => _sources.any((s) => s.isDirty);

  /// Whether some registered source can save its input as a draft.
  bool get canKeep => _sources.any((s) => s.canKeep);

  /// Each source saves its draft, one after the other. A source that cannot keep does nothing.
  Future<void> keep() async {
    for (final source in _sources) {
      await source.keep();
    }
  }

  /// Each source drops its draft and will not save on dispose.
  void discard() {
    for (final source in _sources) {
      source.discard();
    }
  }
}

/// What a page registers in its [LeaveScope] to be asked about (since 0.11.0): implemented by
/// `fespalier_forms`' forms; core knows nothing of forms.
///
/// It is a [Listenable]: the scope rebuilds the page's `PopScope` when it notifies, so a
/// source that turns dirty or clean must notify.
abstract interface class LeaveSource implements Listenable {
  /// Whether leaving would lose input.
  bool get isDirty;

  /// Whether [keep] saves a draft.
  bool get canKeep;

  /// Saves the input as a draft. May be asynchronous.
  FutureOr<void> keep();

  /// Drops the draft, and does not save on dispose.
  void discard();
}

/// The page's place to register [LeaveSource]s (since 0.11.0), found with [maybeOf] below a
/// page whose folder has a `leave.dart`.
final class LeaveScope {
  LeaveScope._(this._owner);

  final _LeaveScopeState _owner;
  final List<LeaveSource> _sources = [];

  /// The scope of the page [context] is in; null in a page without a `leave.dart`.
  static LeaveScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_LeaveScopeInherited>()?.scope;

  /// Registers [source] and returns what unregisters it. Registering is safe during `build`.
  VoidCallback register(LeaveSource source) {
    _sources.add(source);
    source.addListener(_owner._sourcesChanged);
    _owner._sourcesChanged();
    var done = false;
    return () {
      if (done) return;
      done = true;
      source.removeListener(_owner._sourcesChanged);
      _sources.remove(source);
      _owner._sourcesChanged();
    };
  }
}

/// The page instances of each router that have a [LeaveScope], by [pageInstanceId].
final _registry = Expando<Map<String, List<LeaveScope>>>('fespalier leave');

/// The sources registered for the page instance [id] of [router].
List<LeaveSource> _sourcesOf(GoRouter? router, String id) {
  if (router == null) return const [];
  final scopes = _registry[router]?[id];
  if (scopes == null) return const [];
  return [for (final scope in scopes) ...scope._sources];
}

final class _LeaveScopeInherited extends InheritedWidget {
  const _LeaveScopeInherited({required this.scope, required super.child});

  final LeaveScope scope;

  @override
  bool updateShouldNotify(_LeaveScopeInherited oldWidget) => false;
}

/// What a generated page builder wraps the page in when its folder has a `leave.dart`: it
/// registers the page's [LeaveScope] under [state]'s instance and puts a `PopScope` around
/// [child], so the system back and the iOS swipe ask `leave()` too.
///
/// The `PopScope` lets a pop through when the page's route cannot pop (the bottom page of a
/// navigator: go_router then asks `leave()` itself, and `true` closes the app), and, when it
/// can, only if the page has at least one source and every source is clean. Otherwise the back
/// is turned into `GoRouter.pop`, which asks `leave()`. The iOS edge swipe is off while the
/// `PopScope` blocks, and Android's predictive back shows no preview.
Widget leaveScope(GoRouterState state, Widget child) =>
    _LeaveScopeWidget(state: state, child: child);

final class _LeaveScopeWidget extends StatefulWidget {
  const _LeaveScopeWidget({required this.state, required this.child});

  final GoRouterState state;
  final Widget child;

  @override
  State<_LeaveScopeWidget> createState() => _LeaveScopeState();
}

final class _LeaveScopeState extends State<_LeaveScopeWidget> {
  late final LeaveScope _scope = LeaveScope._(this);
  GoRouter? _router;
  String? _id;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(_LeaveScopeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // `/c/1` to `/c/2` keeps this element: the page is another instance now.
    if (pageInstanceId(widget.state) != _id) {
      _detach();
      _attach();
    }
  }

  @override
  void dispose() {
    _detach();
    for (final source in _scope._sources) {
      source.removeListener(_sourcesChanged);
    }
    super.dispose();
  }

  void _attach() {
    final router = GoRouter.maybeOf(context);
    final id = pageInstanceId(widget.state);
    _router = router;
    _id = id;
    if (router == null) return;
    final byId = _registry[router] ??= {};
    (byId[id] ??= []).add(_scope);
  }

  void _detach() {
    final router = _router;
    final id = _id;
    if (router == null || id == null) return;
    final byId = _registry[router];
    final scopes = byId?[id];
    scopes?.remove(_scope);
    if (scopes != null && scopes.isEmpty) byId!.remove(id);
  }

  /// A source registered, went, or turned dirty or clean: the `PopScope` may change.
  void _sourcesChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      // Registered during `build`: this widget is an ancestor of the one building.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = _scope._sources;
    final routeCanPop = ModalRoute.of(context)?.canPop == true;
    final canPop = !routeCanPop || (sources.isNotEmpty && !_anyDirty(sources));
    return _LeaveScopeInherited(
      scope: _scope,
      child: PopScope<Object?>(
        canPop: canPop,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          GoRouter.of(context).pop(result);
        },
        child: widget.child,
      ),
    );
  }

  static bool _anyDirty(List<LeaveSource> sources) =>
      sources.any((s) => s.isDirty);
}

/// What a generated `onExit:` calls (since 0.11.0): [leave] decides whether the page [state]
/// goes, [file] names the `leave.dart` for the error report.
///
/// In order:
///
/// 1. A navigation started inside [leaveWithoutAsking] goes through without asking.
/// 2. A tab switch goes through: fespalier parks the page, it is not gone. Leaving the tab
///    layout asks the active tab's pages only.
/// 3. A prompt already open for this page instance is the answer of a second ask.
/// 4. [leave] runs with a `Ref` of a throwaway provider, kept open until the answer is in, and
///    the [PageLeave] of what the page registered.
/// 5. A `leave()` that throws, now or later, is reported with `FlutterError.reportError`
///    (context `while running leave() of <file>`) and the page goes: a broken `leave()` never
///    traps the user.
///
/// A synchronous answer stays synchronous, with no `Future` and no microtask.
LeaveResult leaveExit(
  BuildContext context,
  GoRouterState state,
  String file,
  LeaveResult Function(Ref ref, PageLeave page) leave,
) {
  final GoRouter? router;
  final ProviderContainer container;
  try {
    router = GoRouter.maybeOf(context);
    if (router != null) {
      if (_bypass[router]?.allows(router) ?? false) return true;
      if (_isTabSwitch(router, state)) return true;
    }
    container =
        (router == null ? null : RouterWatch.peek(router)?.container) ??
        ProviderScope.containerOf(context, listen: false);
  } catch (error, stack) {
    _report(file, error, stack);
    return true;
  }
  final id = pageInstanceId(state);
  final asking = router == null
      ? null
      : (_asking[router] ??= <String, Future<bool>>{});
  final running = asking?[id];
  if (running != null) return running;

  final page = PageLeave(state, _sourcesOf(router, id));
  final provider = Provider.autoDispose<LeaveResult>((ref) {
    try {
      final result = leave(ref, page);
      if (result is! Future<bool>) return result;
      return result.then<bool>(
        (answer) => answer,
        onError: (Object error, StackTrace stack) {
          _report(file, error, stack);
          return true;
        },
      );
    } catch (error, stack) {
      _report(file, error, stack);
      return true;
    }
  }, retry: _noRetry);
  final ProviderSubscription<LeaveResult> sub;
  final LeaveResult result;
  try {
    sub = container.listen<LeaveResult>(provider, (_, _) {}, onError: _ignore);
    try {
      result = sub.read();
    } catch (_) {
      sub.close();
      rethrow;
    }
  } catch (error, stack) {
    _report(file, error, stack);
    return true;
  }
  if (result is! Future<bool>) {
    sub.close();
    return result;
  }
  late final Future<bool> done;
  done = result.whenComplete(() {
    sub.close();
    if (identical(asking?[id], done)) asking!.remove(id);
  });
  asking?[id] = done;
  return done;
}

/// What a generated `onExit:` uses when `leave()` reads the page's segments: a segment that
/// does not parse means the page shows not-found, so there is nothing to ask and the page goes.
LeaveResult leaveWithParams<V>(
  V Function() parse,
  LeaveResult Function(V params) leave,
) {
  final V params;
  try {
    params = parse();
  } on BadSegment {
    return true;
  }
  return leave(params);
}

/// Runs [navigate] without any `leave()` asking (since 0.11.0), for a navigation the user has
/// already decided, such as signing out:
///
/// ```dart
/// leaveWithoutAsking(router, () => ref.read(auth).signOut());
/// ```
///
/// Whatever the navigation asks of the pages that go, now or later (a guard's redirect after
/// the sign-out finishes), is let through while the router's route information is still the one
/// [navigate] left behind; the next navigation makes a new one, and the pages ask again.
void leaveWithoutAsking(GoRouter router, void Function() navigate) {
  final bypass = _bypass[router] ??= _Bypass();
  bypass.during++;
  try {
    navigate();
  } finally {
    bypass.during--;
    bypass.ticket = router.routeInformationProvider.value;
  }
}

final _bypass = Expando<_Bypass>('fespalier leaveWithoutAsking');

/// The prompts open now, by page instance.
final _asking = Expando<Map<String, Future<bool>>>('fespalier leave asking');

final class _Bypass {
  /// Inside `navigate()` of `leaveWithoutAsking`: how deep.
  int during = 0;

  /// The route information the navigation left behind (by identity).
  Object? ticket;

  bool allows(GoRouter router) =>
      during > 0 ||
      (ticket != null &&
          identical(ticket, router.routeInformationProvider.value));
}

Duration? _noRetry(int retryCount, Object error) => null;

void _ignore(Object error, StackTrace stackTrace) {}

void _report(String file, Object error, StackTrace stack) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'fespalier',
      context: ErrorDescription('while running leave() of $file'),
    ),
  );
}

/// Whether the navigation go_router is asking about moves to another tab of a tab layout the
/// exiting page [state] is in: that page is parked, not gone.
///
/// The target is what the route information provider holds: for `goBranch` (`restore`) the
/// match list it carries, for a `go` (and the browser's back and forward) the location matched
/// without redirects. A target that cannot be told is no tab switch, so the page is asked.
bool _isTabSwitch(GoRouter router, GoRouterState state) {
  final config = router.routerDelegate.currentConfiguration;
  final shells = _shellsAround(config.matches, state.pageKey, const []);
  if (shells == null || shells.isEmpty) return false;
  final target = _targetOf(router);
  if (target == null) return false;
  final branches = <ValueKey<String>, Object>{};
  _branchesIn(target.matches, branches);
  return shells.any((s) {
    final there = branches[s.shell];
    return there != null && there != s.branch;
  });
}

/// The tab shells (and their current branch) around the leaf with [pageKey], outermost first;
/// null when no match of [matches] has that key.
List<({ValueKey<String> shell, Object branch})>? _shellsAround(
  List<RouteMatchBase> matches,
  ValueKey<String> pageKey,
  List<({ValueKey<String> shell, Object branch})> around,
) {
  for (final m in matches) {
    if (m is ShellRouteMatch) {
      final inner = m.route is StatefulShellRoute
          ? [...around, (shell: m.pageKey, branch: m.navigatorKey)]
          : around;
      final found = _shellsAround(m.matches, pageKey, inner);
      if (found != null) return found;
    } else if (m is RouteMatch && m.pageKey == pageKey) {
      return around;
    }
  }
  return null;
}

/// The branch each tab shell of [matches] shows.
void _branchesIn(
  List<RouteMatchBase> matches,
  Map<ValueKey<String>, Object> out,
) {
  for (final m in matches) {
    if (m is ShellRouteMatch) {
      if (m.route is StatefulShellRoute) out[m.pageKey] = m.navigatorKey;
      _branchesIn(m.matches, out);
    }
  }
}

/// Where the navigation being applied goes, or null when that is not a `go` or a `restore`.
RouteMatchList? _targetOf(GoRouter router) {
  final value = router.routeInformationProvider.value;
  final info = value.state;
  if (info is RouteInformationState) {
    switch (info.type) {
      case NavigatingType.restore:
        return info.baseRouteMatchList;
      case NavigatingType.go:
        break;
      case NavigatingType.push ||
          NavigatingType.pushReplacement ||
          NavigatingType.replace:
        return null;
    }
  }
  final list = router.configuration.findMatch(value.uri);
  return list.isEmpty ? null : list;
}
