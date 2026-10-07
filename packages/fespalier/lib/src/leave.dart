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

import 'guards.dart' show guardRefreshHooks, guardsContainer, guardsIdle;
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
  final List<bool Function()> _backs = [];

  /// Registers [handler] for the system back on this page and returns what unregisters it
  /// (since 0.11.0). A source that has somewhere to go back to inside the page (a step of a
  /// flow) uses it to go there itself: the handlers run newest first on a back, and the first
  /// that returns true has handled it, so the page is not popped and `leave()` is not asked.
  /// Without one that handles it, the back is turned into `GoRouter.pop` as usual.
  ///
  /// It is consulted by Android's back and by `Navigator.maybePop`, through the page's
  /// `PopScope`, which blocks while a handler is registered, so the iOS edge swipe is off (there
  /// is no back to hand to a handler). That holds on the first page of a navigator too (a step
  /// of a flow is the only page of its shell's navigator): register a handler there only while
  /// it can handle the back, because a handler that declines has no pop to fall back to, and
  /// the back stays on the page. Without a handler, go_router's own fallback asks `leave()` on
  /// the first page.
  VoidCallback onBack(bool Function() handler) {
    _backs.add(handler);
    _owner._sourcesChanged();
    var done = false;
    return () {
      if (done) return;
      done = true;
      _backs.remove(handler);
      _owner._sourcesChanged();
    };
  }

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
    // A back handler blocks the pop wherever the page is: on the first page of a navigator too,
    // where `Navigator.maybePop` asks the handlers only of a `PopScope` that blocks.
    final canPop =
        _scope._backs.isEmpty &&
        (!routeCanPop || (sources.isNotEmpty && !_anyDirty(sources)));
    return _LeaveScopeInherited(
      scope: _scope,
      child: PopScope<Object?>(
        canPop: canPop,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          for (final handler in _scope._backs.reversed.toList()) {
            if (handler()) return;
          }
          // The first page of a navigator has nothing to pop: a handler that declines there has
          // nothing to fall back to, and the back stays on the page.
          if (ModalRoute.of(context)?.canPop != true) return;
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
///    layout asks the active tab's pages only. A switch to a tab with a route that has a
///    `redirect:` (a guard) the page is not already under is asked, since that redirect may
///    take the navigation out of the shell; a top-level `redirect:` of the router cannot be seen
///    and is not asked about.
/// 3. A prompt already open for this page instance is shared by a second ask, which answers
///    `true` only if the page is still there when the first has acted on it: a newer `go` that
///    joins the prompt of an earlier one is refused when that one has taken the page away.
/// 4. [leave] runs with a `Ref` of a throwaway provider, kept open until the answer is in, and
///    the [PageLeave] of what the page registered.
/// 5. A `leave()` that throws, now or later, is reported with `FlutterError.reportError`
///    (context `while running leave() of <file>`) and the page goes: a broken `leave()` never
///    traps the user.
///
/// With [within] (the mount-relative pattern of a flow section, `joinLocation(at, '/signup')`,
/// since 0.11.0), a navigation whose destination is still inside that section goes through
/// without asking: the pages of one multi-page form share one `leave()`, asked once, when the
/// navigation leaves the section. The destination is the route information provider's `uri`
/// for a `go`, `replace` and `pushReplacement`, the target match list of a `restore`, and, for
/// a pop (nothing new was requested), the current configuration without the exiting match.
///
/// A synchronous answer stays synchronous, with no `Future` and no microtask.
LeaveResult leaveExit(
  BuildContext context,
  GoRouterState state,
  String file,
  LeaveResult Function(Ref ref, PageLeave page) leave, {
  String? within,
}) {
  final GoRouter? router;
  final ProviderContainer container;
  try {
    router = GoRouter.maybeOf(context);
    if (router != null) {
      if (_bypass[router]?.allows(router) ?? false) return true;
      if (_isTabSwitch(router, state)) return true;
      if (_isQueryOnlyReplace(router, state)) return true;
      if (within != null && _staysWithin(router, state, within)) return true;
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
  if (running != null) {
    // A second ask shares the open prompt, but only the first to see it answered may act on a
    // `true`: by the time this one runs, the first has taken the page away, and a second pop
    // (or a back that joined a `go`'s prompt) must not complete the match again or close the app.
    return running.then<bool>(
      (ok) =>
          ok &&
          router != null &&
          _shellsAround(
                router.routerDelegate.currentConfiguration.matches,
                state.pageKey,
                const [],
              ) !=
              null,
    );
  }

  final page = PageLeave(state, _sourcesOf(router, id));
  // A provider body runs again when something it watched changes; a prompt must not be asked
  // twice, so the first answer is the answer (and `leave()` should `read`, not `watch`).
  LeaveResult? first;
  final provider = Provider.autoDispose<LeaveResult>((ref) {
    final earlier = first;
    if (earlier != null) return earlier;
    try {
      final result = leave(ref, page);
      if (result is! Future<bool>) return first = result;
      return first = result.then<bool>(
        (answer) => answer,
        onError: (Object error, StackTrace stack) {
          _report(file, error, stack);
          return true;
        },
      );
    } catch (error, stack) {
      _report(file, error, stack);
      return first = true;
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
/// await leaveWithoutAsking(router, () => ref.read(auth).signOut());
/// ```
///
/// It always returns a `Future` (a `navigate` that throws makes it fail, after the window has
/// closed), which completes when the window has:
///
/// 1. No page asks while [navigate] runs, nor while the `Future` it returns is pending, and
///    until the end of the microtask turn it returns in (go_router answers the `onExit` of a
///    `pop` in a microtask).
/// 2. Then it waits for fespalier's own guards to settle what [navigate] changed: the container
///    runs what it scheduled (`pump`), and any asynchronous guard still being evaluated is
///    awaited. The `refresh` a guard asks for in that time is let through (and nothing else
///    is, so a pop made now still asks): a sign-out whose session a guard watches ends at the
///    login page without a question.
///    The pass a refresh took is kept until the router commits what it set going (an async
///    redirect on the way may take as long as it likes), or until the route information changes
///    to something else, so an unrelated navigation ends it; a guard that never answers holds
///    it until then.
/// 3. If [navigate] requested a navigation the router has not committed by then, that one is
///    let through too, while the route information is still the one it left (an identity
///    ticket), until the router's first commit: a one-shot listener, no timer. A request that
///    commits nothing (a `go` to where you are) is closed by the next navigation.
///
/// It never covers a pop after the window, nor a `navigate` that requests nothing: a sign-out
/// that fails leaves every page asking again. A redirect made by a hand-written top-level
/// `redirect:` of the router, settling later than the guards fespalier knows of, is not
/// waited for.
Future<void> leaveWithoutAsking(
  GoRouter router,
  FutureOr<void> Function() navigate,
) {
  final bypass = _bypass[router] ??= _Bypass();
  final start = router.routeInformationProvider.value;
  var committed = false;
  Object? ticket;
  late final VoidCallback onCommit;
  onCommit = () {
    committed = true;
    router.routerDelegate.removeListener(onCommit);
    if (ticket != null) {
      bypass.tickets.remove(ticket);
      ticket = null;
    }
  };
  router.routerDelegate.addListener(onCommit);
  bypass.during++;
  bypass.waiting++;
  // A refresh a guard asks for in the window is let through, and the pass is held to the end
  // of it: an asynchronous guard is evaluated again by the router before it answers `onExit`.
  guardRefreshHooks[router] ??= (refresh) {
    bypass.during++;
    bypass.held++;
    refresh();
    bypass.heldValue = router.routeInformationProvider.value;
  };

  final navigated = Completer<bool>();
  Object? error;
  StackTrace? stack;
  void closeNavigation() {
    if (navigated.isCompleted) return;
    bypass.during--;
    // Whether the route information changed, read now: a pop made right after this returns
    // must not be taken for what `navigate` requested.
    navigated.complete(
      !identical(start, router.routeInformationProvider.value),
    );
  }

  FutureOr<void> result;
  try {
    result = navigate();
  } catch (e, st) {
    error = e;
    stack = st;
    result = null;
  }
  if (result is Future<void>) {
    result.then<void>(
      (_) => closeNavigation(),
      onError: (Object e, StackTrace st) {
        error = e;
        stack = st;
        closeNavigation();
      },
    );
  } else {
    scheduleMicrotask(closeNavigation);
  }

  Future<void> finish() async {
    final requested = await navigated.future;
    try {
      final container =
          RouterWatch.peek(router)?.container ?? guardsContainer(router);
      for (var i = 0; i < 16; i++) {
        if (container != null) await container.pump();
        final idle = guardsIdle(router);
        if (idle == null) break;
        await idle;
      }
    } finally {
      bypass.waiting--;
      if (bypass.waiting == 0) {
        guardRefreshHooks[router] = null;
        // The pass a refresh took is kept until the router commits what it set going (it may
        // evaluate an asynchronous redirect first, however long that takes), or until the route
        // information changes to something else: an unrelated navigation ends it.
        if (committed) {
          bypass.releaseHeld();
        } else {
          bypass.armRelease(router);
        }
      }
      if (committed || !requested) {
        router.routerDelegate.removeListener(onCommit);
      } else {
        ticket = router.routeInformationProvider.value;
        bypass.tickets.add(ticket!);
      }
    }
    final failure = error;
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
  }

  return finish();
}

final _bypass = Expando<_Bypass>('fespalier leaveWithoutAsking');

/// The prompts open now, by page instance.
final _asking = Expando<Map<String, Future<bool>>>('fespalier leave asking');

final class _Bypass {
  /// Inside `navigate()` of `leaveWithoutAsking`, while its `Future` is pending, or running a
  /// guard's refresh in its window.
  int during = 0;

  /// Windows still waiting for the guards.
  int waiting = 0;

  /// The passes taken by guard refreshes in a window, still kept (they are part of [during]).
  int held = 0;

  /// The route information the last refresh left, which only something else changes.
  Object? heldValue;

  VoidCallback? _release;

  /// Gives the held passes back at the router's next commit, or when the route information
  /// becomes something other than [heldValue].
  void armRelease(GoRouter router) {
    if (held == 0 || _release != null) return;
    void onCommit() => releaseHeld();
    void onValue() {
      if (!identical(router.routeInformationProvider.value, heldValue)) {
        releaseHeld();
      }
    }

    router.routerDelegate.addListener(onCommit);
    router.routeInformationProvider.addListener(onValue);
    _release = () {
      router.routerDelegate.removeListener(onCommit);
      router.routeInformationProvider.removeListener(onValue);
    };
  }

  /// Gives the held passes back now.
  void releaseHeld() {
    _release?.call();
    _release = null;
    during -= held;
    held = 0;
  }

  /// The route information of each navigation a window requested that is not committed yet.
  final tickets = <Object>[];

  bool allows(GoRouter router) =>
      during > 0 ||
      tickets.any((t) => identical(t, router.routeInformationProvider.value));
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
  // The target is read before any redirect: a route the page is not already under, with a
  // `redirect:` of its own (a guard), may send the navigation somewhere else, out of the shell
  // too. Then nothing says the page is only parked, so it is asked.
  final known = <RouteBase>{};
  _routesIn(config.matches, known);
  if (_redirectsAbove(target.matches, known)) return false;
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

/// Every route of [matches], shells included.
void _routesIn(List<RouteMatchBase> matches, Set<RouteBase> out) {
  for (final m in matches) {
    out.add(m.route);
    if (m is ShellRouteMatch) _routesIn(m.matches, out);
  }
}

/// Whether a route of [matches] that is not in [known] has a `redirect:`.
bool _redirectsAbove(List<RouteMatchBase> matches, Set<RouteBase> known) {
  for (final m in matches) {
    if (!known.contains(m.route) && m.route.redirect != null) return true;
    if (m is ShellRouteMatch && _redirectsAbove(m.matches, known)) return true;
  }
  return false;
}

/// Whether the navigation go_router is asking about replaces the pushed page [state] with the
/// same page at another query (`replace('/x?q=2')` on a pushed `/x`): the same instance, as it
/// is for a page of the tree, so nothing leaves. `replace` keeps the page's key.
bool _isQueryOnlyReplace(GoRouter router, GoRouterState state) {
  if (state.pageKey.value.startsWith('/')) return false;
  final value = router.routeInformationProvider.value;
  final info = value.state;
  if (info is! RouteInformationState || info.type != NavigatingType.replace) {
    return false;
  }
  final top = info.baseRouteMatchList?.lastOrNull;
  return top is ImperativeRouteMatch &&
      top.pageKey == state.pageKey &&
      value.uri.path == state.uri.path;
}

/// Whether the navigation go_router is asking about ends inside [within], the path of a flow
/// section: `/signup` holds `/signup` and `/signup/contact`, not `/signup-x`.
///
/// The destination is read as [_targetOf] reads it for a tab switch, except that a `push` (which
/// never exits a page), and a navigation whose target cannot be told, are not "within". A pop is
/// what the provider shows no new request for: its destination is where the match list ends once
/// the exiting match is removed.
bool _staysWithin(GoRouter router, GoRouterState state, String within) {
  final value = router.routeInformationProvider.value;
  final info = value.state;
  final config = router.routerDelegate.currentConfiguration;
  final Uri? target;
  if (info is RouteInformationState) {
    switch (info.type) {
      case NavigatingType.restore:
        target = info.baseRouteMatchList?.uri;
      case NavigatingType.go ||
          NavigatingType.replace ||
          NavigatingType.pushReplacement:
        target = value.uri;
      case NavigatingType.push:
        target = null;
    }
  } else {
    target = value.uri;
  }
  if (target == null) return false;
  if (_samePath(target, config.uri)) {
    // Nothing new was requested: a pop. Its destination is the list without the exiting match.
    final exiting = _matchWithKey(config.matches, state.pageKey);
    if (exiting == null) return false;
    final rest = config.remove(exiting);
    return rest.matches.isNotEmpty && _isWithin(rest.uri, within);
  }
  return _isWithin(target, within);
}

bool _samePath(Uri a, Uri b) => a.path == b.path;

bool _isWithin(Uri uri, String within) {
  final base = within.endsWith('/') && within.length > 1
      ? within.substring(0, within.length - 1)
      : within;
  return uri.path == base || uri.path.startsWith('$base/');
}

/// The match of [matches] (into shells) whose page key is [pageKey].
RouteMatchBase? _matchWithKey(
  List<RouteMatchBase> matches,
  ValueKey<String> pageKey,
) {
  for (final m in matches) {
    if (m is ShellRouteMatch) {
      final found = _matchWithKey(m.matches, pageKey);
      if (found != null) return found;
    } else if (m is RouteMatch && m.pageKey == pageKey) {
      return m;
    }
  }
  return null;
}
