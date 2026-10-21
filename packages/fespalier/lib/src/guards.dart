import 'dart:async';

import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show ProviderException;

import 'navigation_kind.dart' show activeMatches, pushedMatches;
import 'segments.dart';

/// Generated redirects call this to chain guards: they run in order and the
/// first one to return a location wins. It stays synchronous until a guard
/// returns a `Future`.
FutureOr<String?> firstRedirect(List<GuardResult Function()> guards) {
  for (var i = 0; i < guards.length; i++) {
    final result = guards[i]();
    if (result is Future<String?>) {
      final rest = guards.sublist(i + 1);
      return result.then((location) => location ?? firstRedirect(rest));
    }
    if (result != null) return result;
  }
  return null;
}

/// Where to go after logging in: [from] (the `?from=` a guard sent along) if
/// it is a location inside this app, otherwise [fallback].
///
/// A guard redirects with `LoginRoute(from: uri.toString()).location`; the
/// login page calls `returnTo(from)` when it is done. Anything that isn't an
/// absolute path in the app (`https://…`, `//host/…`, `javascript:…`) is
/// ignored, so a crafted link can't send people elsewhere.
String returnTo(String? from, {String fallback = '/'}) {
  if (from == null || !from.startsWith('/') || from.startsWith('//')) {
    return fallback;
  }
  if (from.startsWith(r'/\')) return fallback;
  return from;
}

/// What a generated `redirect:` calls for a `guard(Ref ref, {...})`.
///
/// [guard] runs in a fresh `Provider.autoDispose` on every evaluation, so a
/// navigation always asks anew (a guard that only `ref.read`s is never stale) and
/// `ref.watch` inside it is tracked. [site] names the guard on its route (a
/// `const` string the generator writes). The provider stays subscribed while the
/// location the router committed still runs that guard: when something it
/// watches changes and the answer it settles on differs from the one the
/// navigation used, the router is refreshed, so go_router runs the redirects
/// again. The subscription is dropped when a navigation commits without that
/// guard, when [site] is evaluated again, when the widget tree is gone, and
/// with the container.
///
/// A guard that answers synchronously stays synchronous, and an asynchronous
/// one is not wrapped in another `Future`. With no router to refresh (a
/// `redirect:` run by something other than go_router), it is a one-off
/// evaluation.
///
/// A guard that throws, or a re-evaluation that fails, never refreshes the router:
/// the error reaches go_router on a navigation, through the generated [runRedirect]
/// as a [GuardFailure] (since 0.21.0).
FutureOr<String?> refGuard(
  BuildContext context,
  String site,
  GuardResult Function(Ref ref) guard,
) {
  final container = ProviderScope.containerOf(context, listen: false);
  final router = GoRouter.maybeOf(context);
  if (router == null) return _once(container, guard);
  final guards = _guardsOf[router] ??= _RouterGuards(router);
  return guards.run(context, container, site, guard);
}

/// What a generated `redirect:` calls for a `redirect(Ref ref, {...})`.
///
/// It evaluates [redirect] once, in a provider that is closed when the answer is
/// in: a route that redirects never stays on screen, so there is nothing to
/// re-run when what it read changes.
FutureOr<String?> refRedirect(
  BuildContext context,
  GuardResult Function(Ref ref) redirect,
) => _once(ProviderScope.containerOf(context, listen: false), redirect);

Provider<GuardResult> _guardProvider(GuardResult Function(Ref ref) guard) =>
    Provider.autoDispose<GuardResult>(guard, retry: _noRetry);

Duration? _noRetry(int retryCount, Object error) => null;

void _ignore(Object error, StackTrace stackTrace) {}

/// One evaluation: the subscription holds the provider (and what it watches) open
/// until the answer is in, then goes.
FutureOr<String?> _once(
  ProviderContainer container,
  GuardResult Function(Ref ref) guard,
) {
  final ProviderSubscription<GuardResult> sub = container.listen(
    _guardProvider(guard),
    (_, _) {},
    onError: _ignore,
  );
  final GuardResult result;
  try {
    result = sub.read();
  } catch (_) {
    sub.close();
    rethrow;
  }
  if (result is! Future<String?>) {
    sub.close();
    return result;
  }
  return result.whenComplete(sub.close);
}

final _guardsOf = Expando<_RouterGuards>('fespalier guards');

/// The guards of one router that stay subscribed: one per guard site (a route and a guard on it),
/// replaced when that site runs again.
///
/// Since 0.21.0 it also holds the pushed pages of the router (fespalier/fespalier#258). go_router
/// restores a pushed page on a refresh, a restore, a pop back or a hot-reload swap without running
/// its redirect, and a page whose redirect threw is restored as if it had passed. So this class
/// runs the guard of the page on top again (`replace`, which runs the redirects of its entry and
/// keeps its page key), and holds back a page whose guard has not passed in a navigation that
/// pushed it: the router builds nothing for it (`refusedView`). A guard that a pushed page's site
/// watches is re-run on its own page, and a guard that a navigation evaluated is bound to the page
/// that navigation put on top.
final class _RouterGuards {
  _RouterGuards(this._router) {
    _router.routerDelegate.addListener(_committed);
  }

  final GoRouter _router;
  final _live = <String, _Live>{};

  /// The container the guards of this router run in, as the last one that ran saw it.
  ProviderContainer? container;

  var _inFlight = 0;
  final _idleWaiters = <Completer<void>>[];

  /// An asynchronous evaluation started (+1) or ended (-1).
  void _evaluating(int delta) {
    _inFlight += delta;
    if (_inFlight == 0) {
      final waiters = [..._idleWaiters];
      _idleWaiters.clear();
      for (final waiter in waiters) {
        waiter.complete();
      }
    }
  }

  /// Completes when no asynchronous evaluation is in flight; null when none is now.
  Future<void>? idle() {
    if (_inFlight == 0) return null;
    final waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }

  /// The sites evaluated since the router last committed a location.
  final _touched = <String>{};

  /// The pushed pages whose redirects passed in a navigation that pushed them, by page key. A page
  /// that is not here and has a redirect is held back ([refuses]).
  final _passed = <String>{};

  /// The completer each pushed page's `Future` answers to: the one of the navigation that put the
  /// page on top. A re-run forwards its own result there, so the `Future` completes when the page
  /// that stands in for the failed one pops.
  final _completers = <String, Completer<Object?>>{};

  /// The pages whose re-run started in this frame: one re-run per page at a time.
  final _rerunning = <String>{};

  /// The last re-run of each page, until the commit that answers it: the commit of a re-run is not
  /// a navigation of the caller's, so it keeps the completer the caller holds, and what it shows
  /// tells whether the page moved.
  final _reruns = <String, _Rerun>{};

  /// The pages whose re-run is scheduled for after the frame.
  final _scheduled = <String>{};

  /// The configuration the last judgment was made for: one judgment per configuration object.
  RouteMatchList? _judged;

  FutureOr<String?> run(
    BuildContext context,
    ProviderContainer container,
    String site,
    GuardResult Function(Ref ref) guard,
  ) {
    this.container = container;
    final live = _Live(context, owner: this);
    final GuardResult result;
    try {
      live.sub = container.listen(
        _guardProvider(guard),
        (_, next) => _changed(site, live, next),
        onError: _ignore,
      );
      result = live.sub!.read();
    } catch (_) {
      live.close();
      rethrow;
    }
    // The new subscription is open before the old one closes, so the providers both
    // watch are not disposed and fetched again in between.
    _touched.add(site);
    _live.remove(site)?.close();
    _live[site] = live;
    final seq = live.evaluate();
    if (result is! Future<String?>) {
      live.settled(seq, result, used: true);
      return result;
    }
    live.track(
      result,
      (value) => _ping(site, live, live.settled(seq, value, used: true)),
      onError: () {
        if (identical(_live[site], live)) _live.remove(site);
        live.close();
      },
    );
    return result;
  }

  /// Riverpod ran the guard again because something it watched changed.
  void _changed(String site, _Live live, GuardResult next) {
    final seq = live.evaluate();
    if (next is Future<String?>) {
      live.track(
        next,
        (value) => _ping(site, live, live.settled(seq, value, used: false)),
      );
    } else {
      _ping(site, live, live.settled(seq, next, used: false));
    }
  }

  void _ping(String site, _Live live, bool differs) {
    if (!differs || !identical(_live[site], live)) return;
    if (!live.context.mounted) {
      _closeAll();
      return;
    }
    // The router is about to ask again, so the newest answer is the one it uses.
    live.acceptLatest();
    final hook = guardRefreshHooks[_router];
    final owner = live.page;
    if (owner == null) {
      if (hook == null) {
        _router.refresh();
      } else {
        hook(_router.refresh);
      }
      return;
    }
    // A guard of a pushed page: the page is run again, and only while it is on top.
    final top = _topEntry();
    if (top == null || top.pageKey.value != owner || top.matches.isError) {
      _live.remove(site)?.close();
      return;
    }
    // go_router restores the pages under the one on top without their redirects, so a base page
    // that has a guard of its own must be asked again too, whichever site pinged: a sign-out that
    // only moved the top page would leave the base under it, and the system back would land on it
    // signed out. `refresh()` asks the base: when its redirect moves it, the whole stack is
    // replaced, as it was before the pushed page's guard watched anything (before 0.21.0); when it
    // keeps its place, `_judge` runs the page on top again after that commit. A base with no guard
    // has nothing to ask, so the pushed page is run again at once.
    final VoidCallback run = _baseGuarded()
        ? _router.refresh
        : () => _rerun(top);
    if (hook == null) {
      run();
    } else {
      hook(run);
    }
  }

  /// Whether the page at the bottom of the stack, which a `refresh()` asks again, is under a
  /// redirect (its own, a parent's or a shell's): the pushed pages are not looked at.
  bool _baseGuarded() =>
      _hasRedirect(_router.routerDelegate.currentConfiguration.matches);

  /// Runs the guard of the pushed page [entry] again, as a navigation that replaces the page with
  /// the same location and `extra`: go_router runs the redirects of the entry, keeps its page key
  /// and leaves the stack below alone. The `Future` of that navigation completes the completer the
  /// page answers to (see [_completers]). One re-run per page at a time.
  ///
  /// The re-run asks `leave()` of the page only when it moves it (see [guardRerunMoves]).
  void _rerun(ImperativeRouteMatch entry) {
    final key = entry.pageKey.value;
    if (!_rerunning.add(key)) return;
    final target = _completers[key] ?? entry.completer;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _rerunning.remove(key);
    });
    final rerun = _reruns[key] = _Rerun(entry.matches.uri);
    final Future<Object?> answer;
    try {
      answer = _router.replace<Object?>(
        entry.matches.uri.toString(),
        extra: entry.matches.extra,
      );
    } finally {
      rerun.info = _router.routeInformationProvider.value;
    }
    answer.then<void>(
      (value) => _completeWith(target, value),
      onError: (Object error, StackTrace stack) {
        if (!target.isCompleted) target.completeError(error, stack);
      },
    );
  }

  /// Completes [target], the `Future` of the push that opened a page, with [value], what the page
  /// that stands in for it popped with.
  ///
  /// [target] was made for the type that push asked for (`push<int>`), and the page in its place may
  /// pop with another one (a guard that sends `/pick` to a sign-in page that pops a `String`): the
  /// completer refuses it with a `TypeError`. The push then completes with `null`, as if its page had
  /// been popped without a result, and never hangs; no error reaches the caller, who awaits a result
  /// of the type it asked for. A debug build reports the mismatch with `FlutterError.reportError` (the
  /// type of [value] only, never the value); a release build says nothing.
  static void _completeWith(Completer<Object?> target, Object? value) {
    if (target.isCompleted) return;
    try {
      target.complete(value);
    } on TypeError {
      target.complete(null);
      // Debug builds only: an `assert`, because this file names no build mode (the report of a failed
      // guard is made in all of them, and a test pins that).
      assert(() {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: FlutterError(
              'The page that replaced a pushed page popped with a ${value.runtimeType}, which the '
              '`push` that opened it does not ask for.\n'
              'Its Future completed with null instead. A guard re-ran the pushed page and sent it '
              'to a page whose result has another type than the push\'s.',
            ),
            library: 'fespalier',
            context: ErrorDescription(
              'while completing the Future of a push whose page a guard replaced',
            ),
          ),
        );
        return true;
      }());
    }
  }

  /// Runs the re-run of [key] after the frame, once, when it is still on top then.
  void _schedule(String key) {
    if (!_scheduled.add(key)) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled.remove(key);
      final top = _topEntry();
      if (top == null || top.pageKey.value != key || top.matches.isError) {
        return;
      }
      _rerun(top);
    });
  }

  /// The router committed a location: the navigation's sites are bound to the page it put on top,
  /// the rest are no longer watched. See [_judge].
  void _committed() => _judgeNow();

  /// Judges the committed [config] once (since 0.21.0). [pushPath] says whether the navigation
  /// pushed a page (`push`, `pushReplacement`, `replace`): then its redirects ran, and a page on top
  /// passed or failed them.
  ///
  /// - The sites the navigation evaluated are bound to the page on top (null for the base). A
  ///   navigation that failed closes them all: a page that never showed has nothing to keep up to
  ///   date (a refresh that one of them asked for would show the guarded page, #258).
  /// - A site bound to a page stays live while that page is on top, and is closed when it is covered
  ///   or gone. A site the navigation did not evaluate and that is bound to no page is closed.
  /// - A pushed page that is on top and was not pushed by this navigation (a refresh, a restore, a
  ///   pop back, a tab, a swap) runs its guard again, after the frame.
  void _judge(RouteMatchList config, bool pushPath) {
    if (identical(config, _judged)) return;
    _judged = config;
    final pushed = <ImperativeRouteMatch>[];
    pushedMatches(config.matches, pushed);
    final failed = activeMatches(config, pushed).error is GuardFailure;
    final top = pushed.isEmpty ? null : pushed.last;
    final shown = top != null && !top.matches.isError ? top : null;
    final shownKey = shown?.pageKey.value;

    final stale = <String>[];
    for (final site in _live.keys) {
      final live = _live[site]!;
      if (failed) {
        stale.add(site);
      } else if (_touched.contains(site)) {
        live.page = pushPath ? shownKey : null;
      } else if (live.page == null || live.page != shownKey) {
        stale.add(site);
      }
    }
    for (final site in stale) {
      _live.remove(site)?.close();
    }
    _touched.clear();

    if (pushPath && top != null) {
      final key = top.pageKey.value;
      if (top.matches.isError) {
        _passed.remove(key);
      } else {
        _passed.add(key);
      }
      // A re-run's own commit keeps the completer the caller holds; any other commit is the
      // caller's navigation, and its completer is the one to answer.
      final rerun = _reruns.remove(key);
      if (rerun == null) {
        _completers[key] = top.completer;
      } else if (top.matches.isError || top.matches.uri != rerun.uri) {
        // The page moved, or its guard failed: `replace` keeps the page key, so the Navigator keeps
        // the dialogs and sheets over it, and they are the old page's.
        _closeOver(config.matches, key);
      }
    }
    final keys = {for (final e in pushed) e.pageKey.value};
    _passed.removeWhere((k) => !keys.contains(k));
    _completers.removeWhere((k, _) => !keys.contains(k));
    _reruns.removeWhere((k, _) => !keys.contains(k));

    if (!pushPath && shown != null && _guarded(shown)) {
      _schedule(shownKey!);
    }
  }

  /// Closes the routes without a page (dialogs, sheets) that lie over the pushed page [key] and
  /// over its navigator's shells, as the retry of an error view does ([_closeRoutesOver]): the page
  /// stays, with what it shows replaced, and what the person opened over the old page does not
  /// belong to the new one. Not in a build, where a navigator may not be changed: after the frame.
  void _closeOver(List<RouteMatchBase> matches, String key) {
    final navigators = <GlobalKey<NavigatorState>>[];
    _navigatorsAround(matches, key, navigators);
    navigators.add(_router.routerDelegate.navigatorKey);
    void close() {
      for (final navigator in navigators) {
        navigator.currentState?.popUntil(_hasPage);
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => close());
    } else {
      close();
    }
  }

  /// A redirect of the navigation in flight answered with a location, or failed: a re-run that is
  /// in flight moves its page.
  void _answered() {
    for (final rerun in _reruns.values) {
      if (rerun.current(_router)) rerun.moves = true;
    }
  }

  /// The pushed page on top, or null when none is pushed.
  ImperativeRouteMatch? _topEntry() {
    final pushed = <ImperativeRouteMatch>[];
    pushedMatches(_router.routerDelegate.currentConfiguration.matches, pushed);
    return pushed.isEmpty ? null : pushed.last;
  }

  /// Whether [entry]'s page is held back: a page with a redirect that no navigation pushing it has
  /// passed (a restored page, or a failed one).
  bool _held(ImperativeRouteMatch entry) =>
      !entry.matches.isError &&
      !_passed.contains(entry.pageKey.value) &&
      _guarded(entry);

  /// Judges the configuration the router shows now, if no one did yet: the first reader of what a
  /// commit passed does the work, whoever it is (the page gate, `RouterWatch`, DevTools, this
  /// class's own listener). The listener of `RouterWatch` is attached before this class's, so at a
  /// commit it asks first, and [_passed] must already hold the key the commit put on top.
  void _judgeNow() => _judge(
    _router.routerDelegate.currentConfiguration,
    _isPushNavigation(_router),
  );

  /// Whether [entry] is held back: see [_held].
  bool refusesEntry(ImperativeRouteMatch entry) {
    _judgeNow();
    return _held(entry);
  }

  /// Whether the pushed page whose page key is [key] is held back: its page builds nothing
  /// (`refusedView`). A page is told by its key, not by its location: a base page may have the
  /// location of a held one.
  bool refuses(String key) {
    _judgeNow();
    final pushed = <ImperativeRouteMatch>[];
    pushedMatches(_router.routerDelegate.currentConfiguration.matches, pushed);
    return pushed.any((e) => e.pageKey.value == key && _held(e));
  }

  void _closeAll() {
    for (final live in _live.values) {
      live.close();
    }
    _live.clear();
    _touched.clear();
  }
}

/// Whether [entry]'s route chain has a redirect (its own, or a route or shell above it in the pushed
/// navigation).
bool _guarded(ImperativeRouteMatch entry) =>
    _hasRedirect(entry.matches.matches);

bool _hasRedirect(List<RouteMatchBase> matches) {
  for (final m in matches) {
    if (m is ImperativeRouteMatch) continue;
    if (m is ShellRouteMatch) {
      if (m.route.redirect != null || _hasRedirect(m.matches)) return true;
    } else if (m is RouteMatch && m.route.redirect != null) {
      return true;
    }
  }
  return false;
}

/// Collects into [out] the navigator keys of the shells that hold the pushed page [key], outermost
/// first; true when the page is found.
bool _navigatorsAround(
  List<RouteMatchBase> matches,
  String key,
  List<GlobalKey<NavigatorState>> out,
) {
  for (final m in matches) {
    if (m is ImperativeRouteMatch) {
      if (m.pageKey.value == key) return true;
    } else if (m is ShellRouteMatch) {
      out.add(m.navigatorKey);
      if (_navigatorsAround(m.matches, key, out)) return true;
      out.removeLast();
    }
  }
  return false;
}

/// Whether [router] is in a navigation that pushes a page (`push`, `pushReplacement` or `replace`):
/// the information it holds says so until the router reports the location it committed.
bool _isPushNavigation(GoRouter router) {
  final state = router.routeInformationProvider.value.state;
  if (state is! RouteInformationState) return false;
  return switch (state.type) {
    NavigatingType.push ||
    NavigatingType.pushReplacement ||
    NavigatingType.replace => true,
    _ => false,
  };
}

/// What the re-run of the guard of the pushed page [pageKey] on [router] does to the page that
/// `leaveExit` is asked about, while go_router asks it to leave (since 0.21.0): null when no re-run
/// of the page is in flight, true when one of its redirects answered a location or failed (the page
/// moves, and `leave()` is asked as it is for a base page's redirect), false when the guards passed
/// again (the page is replaced by itself, and nothing is asked).
///
/// A re-run is the navigation `replace` of the page with its own location; it is in flight while the
/// router's route information is the one that `replace` put there, and a redirect that does not run
/// through `runRedirect` is not seen, so such a re-run is taken for one that passes.
bool? guardRerunMoves(GoRouter router, String pageKey) {
  final rerun = _guardsOf[router]?._reruns[pageKey];
  if (rerun == null || !rerun.current(router)) return null;
  return rerun.moves;
}

/// Whether [entry], a pushed page of [router], is held back (see `_RouterGuards._held`): it is a
/// page the walk of `RouterWatch` treats as an error view, which covers the page below it.
bool refusedEntry(GoRouter router, ImperativeRouteMatch entry) =>
    _guardsOf[router]?.refusesEntry(entry) ?? false;

/// One re-run of a pushed page's guard (see [_RouterGuards._rerun]).
final class _Rerun {
  _Rerun(this.uri);

  /// The page's location before the re-run: the page moved when the commit shows another one.
  final Uri uri;

  /// The route information the `replace` of the re-run put in the router's provider, null while
  /// that call has not returned (a guard that answers at once is run inside it).
  Object? info;

  /// Whether a redirect of the re-run answered a location or failed.
  bool moves = false;

  /// Whether the router is still on the navigation of this re-run.
  bool current(GoRouter router) =>
      info == null || identical(info, router.routeInformationProvider.value);
}

/// One evaluation of a guard site and its subscription.
final class _Live {
  _Live(this.context, {this.owner});

  /// The router's guards, told when an evaluation starts and ends.
  final _RouterGuards? owner;

  /// The page key of the pushed page this guard is bound to (since 0.21.0), null for the base: the
  /// guard runs again on that page while it is on top.
  String? page;

  /// Where the guard last ran: when it is gone, so is the app.
  final BuildContext context;
  ProviderSubscription<GuardResult>? sub;

  var _evaluations = 0;
  var _pending = 0;
  var _closing = false;

  /// The answer the navigation used, and the newest one that has settled since.
  var _usedKnown = false;
  String? _used;
  var _latestSeq = 0;
  var _latestKnown = false;
  String? _latest;

  /// A number for an evaluation, so an older one that settles late does not win.
  int evaluate() => ++_evaluations;

  /// Records an answer; true when the navigation's and the newest differ.
  bool settled(int seq, String? value, {required bool used}) {
    if (used) {
      _usedKnown = true;
      _used = value;
    }
    if (seq >= _latestSeq) {
      _latestSeq = seq;
      _latestKnown = true;
      _latest = value;
    }
    return _usedKnown && _latestKnown && _used != _latest;
  }

  /// The router is about to ask again: what it will use is the newest answer.
  void acceptLatest() => _used = _latest;

  /// Follows an asynchronous answer. An error is the navigation's to handle (the
  /// first answer) or nobody's (an answer to a later change), never unhandled here.
  void track(
    Future<String?> answer,
    void Function(String? value) then, {
    void Function()? onError,
  }) {
    _pending++;
    owner?._evaluating(1);
    answer
        .then<void>(
          then,
          onError: (Object _) {
            onError?.call();
          },
        )
        .whenComplete(() {
          _pending--;
          if (_closing && _pending == 0) sub?.close();
          owner?._evaluating(-1);
        });
  }

  /// Closes the subscription, but not under an evaluation still awaiting: its `ref`
  /// would be disposed under it, and a `ref.watch` after an `await` would throw.
  void close() {
    _closing = true;
    if (_pending == 0) sub?.close();
  }
}

/// The container the guards of [router] last ran in, for `leaveWithoutAsking`; null when none ran.
ProviderContainer? guardsContainer(GoRouter router) =>
    _guardsOf[router]?.container;

/// Completes when no asynchronous guard of [router] is being evaluated; null when none is now.
/// What `leaveWithoutAsking` waits for before it closes its window.
Future<void>? guardsIdle(GoRouter router) => _guardsOf[router]?.idle();

/// Runs the refresh a guard asks for in `leaveWithoutAsking`'s window, when one is open for the
/// router: the hook runs it with the bypass on.
final guardRefreshHooks = Expando<void Function(void Function() refresh)>(
  'fespalier guard refresh',
);

/// What go_router gets when a guard or a `redirect.dart` fails (since 0.21.0): it threw, or the
/// `Future` it returned completed with an error.
///
/// The generated `redirect:` runs its guards through [runRedirect], which hands go_router this
/// exception in place of the failure. go_router passes a [GoException] on as it is, so the router's
/// error route has it as `GoRouterState.error` (and `onException` gets it): the generated
/// `AppRoutes.errorPage` reports it once, in every build mode, and shows the route's `error.dart`, or
/// its not-found view. [error] and [stackTrace] are what the guard threw, unwrapped from Riverpod's
/// `ProviderException`: they are what a crash reporter should see, not this wrapper.
final class GuardFailure extends GoException {
  /// Wraps [error], which a guard or a `redirect.dart` threw with [stackTrace].
  GuardFailure(this.error, this.stackTrace)
    : super('a guard or redirect.dart failed with ${error.runtimeType}');

  /// What the guard or `redirect.dart` threw, or what its `Future` failed with.
  final Object error;

  /// Where [error] was thrown.
  final StackTrace stackTrace;

  /// Whether [routerErrorPage] reported it: once, however often the error page builds.
  bool _reported = false;

  @override
  String toString() => 'GuardFailure: $error';
}

/// go_router's zone value for the router a redirect runs for (`currentRouterKey`, internal to
/// go_router, the same from 17.2.3 to 18.1.1).
const Symbol _goRouterZoneKey = #goRouterRedirectContext;

/// What a generated `redirect:` runs its guards and its `redirect.dart` through (since 0.21.0):
/// `redirect: (context, state) => runRedirect(() => traceGuard(...))`.
///
/// A guard or `redirect.dart` that throws, or whose `Future` fails, reaches go_router as a
/// [GuardFailure] (what it threw and its stack trace, Riverpod's `ProviderException` taken off), so
/// the router shows its error route on every go_router fespalier allows. A synchronous answer is
/// returned as it is, the very object: a sync guard stays sync, with no `Future`, microtask or
/// timer. An asynchronous answer comes back as a `Future` of its own, with the same value or the
/// [GuardFailure]. `traceGuard` and the telemetry inside still see the guard's own result.
///
/// go_router 17.2.3 to 18.1.0 run a redirect in an error zone of their own (`runZonedGuarded`), from
/// which a failed `Future` never reaches the code that awaits it: the failure was uncaught and the
/// navigation never ended. There, [redirect] runs where go_router 18.1.1 runs it: in a plain fork of
/// the zone that called go_router, with go_router's router value. Anywhere else (go_router 18.1.1, no
/// router, a zone of the app's own) it runs in the current zone.
FutureOr<String?> runRedirect(GuardResult Function() redirect) {
  final zone = Zone.current;
  final parent = zone.parent;
  final router = zone[_goRouterZoneKey];
  // A redirect that runs for a push holds the pushed page's guard from here on (fespalier/fespalier#258):
  // go_router will restore that page later without running the redirect.
  _RouterGuards? guards;
  if (router is GoRouter) {
    guards = _guardsOf[router];
    if (guards == null && _isPushNavigation(router)) {
      guards = _guardsOf[router] = _RouterGuards(router);
    }
    // Only while a re-run of a pushed page is on the way does an answer need a word to the router.
    if (guards != null && guards._reruns.isEmpty) guards = null;
  }
  if (router != null &&
      parent != null &&
      parent[_goRouterZoneKey] == null &&
      !zone.inSameErrorZone(parent)) {
    return parent
        .fork(zoneValues: {_goRouterZoneKey: router})
        .run(() => _redirect(redirect, guards));
  }
  return _redirect(redirect, guards);
}

/// Runs [redirect] for [runRedirect]. When [rerunning] is given, a re-run of a pushed page is on the
/// way, and an answer that moves the page (a location, or a failure) is told to it: `leave()` is
/// asked only of a page that a re-run moves (see [guardRerunMoves]).
FutureOr<String?> _redirect(
  GuardResult Function() redirect,
  _RouterGuards? rerunning,
) {
  final GuardResult result;
  try {
    result = redirect();
  } catch (error, stackTrace) {
    final failure = _failure(error, stackTrace);
    rerunning?._answered();
    Error.throwWithStackTrace(failure, failure.stackTrace);
  }
  if (result is! Future<String?>) {
    if (result != null) rerunning?._answered();
    return result;
  }
  return result.then<String?>(
    rerunning == null
        ? _same
        : (location) {
            if (location != null) rerunning._answered();
            return location;
          },
    onError: (Object error, StackTrace stackTrace) {
      final failure = _failure(error, stackTrace);
      rerunning?._answered();
      Error.throwWithStackTrace(failure, failure.stackTrace);
    },
  );
}

String? _same(String? location) => location;

/// [error] as a [GuardFailure]: one already is, and a `ProviderException` gives what it wraps.
GuardFailure _failure(Object error, StackTrace stackTrace) {
  var e = error;
  var s = stackTrace;
  while (e is ProviderException) {
    s = e.stackTrace;
    e = e.exception;
  }
  return e is GuardFailure ? e : GuardFailure(e, s);
}

/// How the report of a [GuardFailure] says where it came from (Flutter prints "... was thrown while
/// running a guard or redirect.dart").
const _guardFailureContext = 'while running a guard or redirect.dart';

/// What the router shows for go_router's error route (since 0.21.0): the generated
/// `AppRoutes.errorPage` calls it with the app's `notFound` and, when some route can show a failed
/// guard, its `guardError`.
///
/// When `state.error` is a [GuardFailure], it is reported once, in every build mode, with
/// `FlutterError.reportError` (library `fespalier`, what the guard threw and its stack trace): a
/// widget test fails unless it calls `tester.takeException()`, and in a release build
/// `FlutterError.onError` hears it, which is where `SentryFlutter.init` listens. [guardError] builds
/// the view of the route at `state.uri` with a retry that runs the navigation again, only while the
/// router still shows this failure. Without a view, [notFound] shows. Any other error (no route matched, a
/// redirect loop, too many redirects) is [notFound]. It makes no `Future` and starts no timer.
///
/// The failure reaches the error route in one of two places. After `go`, a link or the first
/// location, it is the router's own error (`GoRouter.refresh` runs the navigation again). After
/// `push`, and `pushReplacement` and `replace` over other pages, go_router puts the failed list in an
/// entry on top of the stack and the router's own `error` stays null: the retry then closes that
/// entry with the same location and `extra` again, and keeps its page key (since 0.21.0). The `Future`
/// of the `push` that failed completes with the result of the page in its place when that page pops
/// (`null` when it is popped without one). A dialog, a sheet or
/// another route without a page over the error view is closed first, so the retry replaces the
/// error view and not the dialog. A retry held after the router moved on (the entry closed, another
/// page above it) does nothing.
Widget routerErrorPage(
  BuildContext context,
  GoRouterState state,
  Widget Function(Uri uri) notFound, {
  Widget? Function(
    Uri uri,
    Object error,
    StackTrace stackTrace,
    VoidCallback retry,
  )?
  guardError,
}) {
  final failure = state.error;
  if (failure is! GuardFailure) return notFound(state.uri);
  if (!failure._reported) {
    failure._reported = true;
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: failure.error,
        stack: failure.stackTrace,
        library: 'fespalier',
        context: ErrorDescription(_guardFailureContext),
      ),
    );
  }
  final router = GoRouter.maybeOf(context);
  // The view is built inside the error page's route, so its retry can tell which navigator the
  // pages are in, and what lies over the view.
  return Builder(
    builder: (inside) {
      void retry() {
        if (router != null) _retry(router, failure, inside);
      }

      return guardError?.call(
            state.uri,
            failure.error,
            failure.stackTrace,
            retry,
          ) ??
          notFound(state.uri);
    },
  );
}

/// Runs again the navigation that failed with [failure], if the router still shows it: see
/// [routerErrorPage]. [inside] is a context inside the error view.
void _retry(GoRouter router, GuardFailure failure, BuildContext inside) {
  final config = router.routerDelegate.currentConfiguration;
  if (identical(config.error, failure)) {
    router.refresh();
    return;
  }
  // A pushed navigation: go_router keeps its failed list in the entry it pushed, which is the
  // page on top (the last pushed entry, however deep in the shells) while the error view shows.
  // A page pushed over it makes another entry the last one, and the retry does nothing.
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(config.matches, pushed);
  if (pushed.isEmpty || !identical(pushed.last.matches.error, failure)) return;
  // Only dialogs, sheets and other routes without a page can be over the error view now: close
  // them first, or the navigation below would leave them over the view.
  _closeRoutesOver(inside);
  // The entry is replaced in place (its key stays), and its `Future` answers the caller's
  // (see `_RouterGuards._rerun`).
  (_guardsOf[router] ??= _RouterGuards(router))._rerun(pushed.last);
}

/// What a guarded route's page shows in place of its page (since 0.21.0): the generated page
/// builder is `refusedView(context, state) ?? <page>`, so the page is not built while [state] is a
/// pushed page that has not passed its guard (fespalier/fespalier#258). Null when the page may be
/// built: at once for every page of a router with no pushed page.
///
/// A held page shows nothing (an empty box): the guard of the page is run again after the frame, and
/// its navigation shows the error view of a failure, or the page of a pass. It makes no `Future`,
/// and it reports nothing.
Widget? refusedView(BuildContext context, GoRouterState state) {
  // A base page's key is its matched path (`/orders/:id`, so it starts with `/`), and go_router
  // makes a pushed page's key from letters and symbols that are never a `/`: a base page is never
  // held, whatever else is, and costs no lookup.
  final key = state.pageKey.value;
  if (key.startsWith('/')) return null;
  final router = GoRouter.maybeOf(context);
  if (router == null) return null;
  if (_guardsOf[router] == null) {
    final pushed = <ImperativeRouteMatch>[];
    pushedMatches(router.routerDelegate.currentConfiguration.matches, pushed);
    if (pushed.isEmpty) return null;
  }
  final guards = _guardsOf[router] ??= _RouterGuards(router);
  return guards.refuses(key) ? const SizedBox.shrink() : null;
}

/// Closes what lies over the page that [inside] is in (since 0.21.0): the routes without a `Page`
/// on top of its navigator, and on top of the root one when the page is in a nested navigator
/// (`showDialog`'s default). Routes that have a page are left alone.
void _closeRoutesOver(BuildContext inside) {
  if (!inside.mounted) return;
  final nearest = Navigator.maybeOf(inside);
  final root = Navigator.maybeOf(inside, rootNavigator: true);
  nearest?.popUntil(_hasPage);
  if (root != nearest) root?.popUntil(_hasPage);
}

bool _hasPage(Route<Object?> route) => route.settings is Page<Object?>;
