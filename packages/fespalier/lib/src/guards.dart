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

  /// The sites evaluated since the router last committed a location, by navigations that bind their
  /// sites when they commit (a `replace` of a pushed page binds them when it evaluates them: see
  /// [run]). Every commit takes them and clears the set (see [_judge]).
  ///
  /// It holds only the sites of the navigation being committed. A navigation that commits nothing (a
  /// `leave()` that refuses it, a guard that never answers, the restore of the stack on screen that
  /// cancels a re-run, a navigation another one superseded) leaves its sites here, and the next
  /// commit, whatever it is, takes them for its own and binds them to the page it puts on top (or to
  /// the base). That is harmless: a guard pings only when its own answer changes, and the ping then
  /// refreshes the router when the base is under a redirect, or runs the redirects of the page on
  /// top again, which do not include the guard, so a page that passes them stays where it is. The
  /// next commit after that closes the site like any other that is not on its page.
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

  /// The last re-run of each page, until a commit on that page: the commit of a re-run is not a
  /// navigation of the caller's, so it keeps the completer the caller holds, and what it shows tells
  /// whether the page moved. A commit of any other navigation (the router no longer holds the
  /// re-run's) takes the entry away, and answers to its own completer. A re-run that never landed
  /// (its landing was refused) stays until then.
  final _reruns = <String, _Rerun>{};

  /// The pages whose re-run is scheduled for after the frame.
  final _scheduled = <String>{};

  /// The pages whose re-run is scheduled again, after a landing that was refused (see [_askAgain]).
  final _askingAgain = <String>{};

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
    //
    // A guard evaluated for the `replace` of a pushed page (a re-run of its guard is one) belongs to
    // that page from the start: `replace` keeps the page key, and the navigation may end without a
    // commit (a `leave()` that refuses the move, a guard that never answers), after which nothing
    // would tell where the guard stood. Any other navigation says which page it puts on top when it
    // commits.
    final replaced = _replacedPage();
    if (replaced == null) {
      _touched.add(site);
    } else {
      live.page = replaced;
    }
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

  /// The page key of the pushed page that the navigation being applied replaces in place, null when
  /// it is not a `replace` of a pushed page.
  String? _replacedPage() {
    final info = _router.routeInformationProvider.value.state;
    if (info is! RouteInformationState || info.type != NavigatingType.replace) {
      return null;
    }
    final pushed = <ImperativeRouteMatch>[];
    pushedMatches(info.baseRouteMatchList?.matches ?? const [], pushed);
    return pushed.isEmpty ? null : pushed.last.pageKey.value;
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
    // A guard of a pushed page: the page is run again, and only while it is on top.
    final top = owner == null ? null : _topEntry();
    if (owner != null &&
        (top == null || top.pageKey.value != owner || top.matches.isError)) {
      _live.remove(site)?.close();
      return;
    }

    // go_router restores the pages under the one on top without their redirects, so a base page that
    // is under a redirect must be asked again too, whichever site pinged: a sign-out that only moved
    // the top page would leave the base under it, and the system back would land on it signed out.
    // `refresh()` asks the base. When its redirect moves it, the whole stack is replaced, as it was
    // before the pushed page's guard watched anything (before 0.21.0). When it keeps its place, the
    // commit of the refresh runs the page on top again, after the frame (see [_judge]). A base under
    // no redirect has nothing to ask, so the pushed page alone is run again, at once.
    //
    // The price, over a base that is under a redirect: a change that only the pushed page's guard
    // notices (a role revoked while the session holds) is a refresh, for which go_router restores the
    // pushed page with a new entry (and asks it to leave), and then the re-run that moves it. A dirty
    // page's `leave()` can be asked twice, once for each; a guard that passes again asks it once, for
    // the refresh alone. A base that redirects asks it once, as before 0.21.0. docs/guards.md says
    // so. Telling the two apart in advance means reading the base's guards where they are, and an
    // asynchronous guard or a `redirect:` that is no fespalier guard cannot be read: it was tried,
    // and the bookkeeping it needed was wrong in more places than the question it saved.
    final VoidCallback run = top == null || _baseGuarded()
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
      _rerunIfTop(key);
    });
  }

  /// Runs the re-run of the pushed page [key] again, after its last landing was refused without a
  /// question (see [guardRerunRefused]): the guard wanted to move the page, and nobody vetoed it, so
  /// it asks once the question has settled, or moves the page.
  ///
  /// On the frame after the refusal, and not in the callback after the frame that is on its way.
  /// That frame is the one in which the router reports the configuration it kept, in a callback it
  /// registers after this method is called, and the report replaces the route information the new
  /// re-run put there: the re-run would no longer be the navigation the router holds
  /// ([_Rerun.current]) and its landing would be taken for a question of the person's. The frame is
  /// asked for when none is on its way; there is no timer.
  void _askAgain(String key) {
    if (!_askingAgain.add(key)) return;
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      binding.addPostFrameCallback((_) {
        _askingAgain.remove(key);
        _rerunIfTop(key);
      });
      binding.ensureVisualUpdate();
    });
    if (binding.schedulerPhase == SchedulerPhase.idle) {
      binding.ensureVisualUpdate();
    }
  }

  /// Runs the re-run of [key] when it is the pushed page on top and shows a page.
  void _rerunIfTop(String key) {
    final top = _topEntry();
    if (top == null || top.pageKey.value != key || top.matches.isError) return;
    _rerun(top);
  }

  /// The router committed a location: the navigation's sites are bound to the page it put on top,
  /// the rest are no longer watched. See [_judge].
  void _committed() => _judgeNow();

  /// Judges the committed [config] once (since 0.21.0). The commit is a push when the navigation
  /// the router holds put the page on top (`push`, `pushReplacement`, `replace`, see
  /// [_landedFromRequest]): then its redirects ran, and that page passed or failed them. Any other
  /// commit (a refresh, a restore, a pop back, a tab, a swap) shows a page whose redirects did not
  /// run.
  ///
  /// - The sites the navigation evaluated are bound to the page on top (null for the base). A
  ///   navigation that failed closes them all: a page that never showed has nothing to keep up to
  ///   date (a refresh that one of them asked for would show the guarded page, #258).
  /// - A site bound to a page stays live while that page is on top, and is closed when it is covered
  ///   or gone. A site the navigation did not evaluate and that is bound to no page (the base's) is
  ///   closed too, under any pushed page, guarded or not, as it was before 0.21.0: a guarded page
  ///   under a pushed page waits for the pop. A change only the pushed page's guard notices asks the
  ///   base with a refresh when the base is under a redirect (see [_ping]).
  /// - A pushed page that is on top and was not pushed by this navigation (a refresh, a restore, a
  ///   pop back, a tab, a swap) runs its guard again, after the frame.
  void _judge(RouteMatchList config) {
    if (identical(config, _judged)) return;
    _judged = config;
    final pushed = <ImperativeRouteMatch>[];
    pushedMatches(config.matches, pushed);
    final failed = activeMatches(config, pushed).error is GuardFailure;
    final top = pushed.isEmpty ? null : pushed.last;
    final pushPath = _landedFromRequest(_router, top);
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
      // caller's navigation, and its completer is the one to answer. The entry of a re-run that
      // never landed (its `leave()` refused it, or the person's question was open) stays here, and
      // the router has gone on to another navigation by the time something commits: a commit of the
      // app's own on that page (`replace`) is the caller's, and takes the entry away unused. Only the
      // navigation the router still holds is the re-run's (see [_Rerun.current]).
      final rerun = _reruns.remove(key);
      if (rerun == null || !rerun.current(_router)) {
        _completers[key] = top.completer;
      } else if (top.matches.isError || top.matches.uri != rerun.uri) {
        // The page moved, or its guard failed: `replace` keeps the page key, so the Navigator keeps
        // the dialogs and sheets over it, and they are the old page's.
        _closeOver(config.matches, key);
      }
    }
    final keys = {for (final e in pushed) e.pageKey.value};
    // A page that went (a pop, the system back) while its re-run is still waiting for its guard:
    // that navigation will land later, on the stack as it was when the re-run started, and bring
    // the page back. A pop go_router did not make through its route information (the app bar's back
    // button, `Navigator.pop`, the pop of a page with a `leave.dart`) does not cancel it.
    final leftWaiting = _reruns.entries.any(
      (e) =>
          !keys.contains(e.key) && e.value.waiting && e.value.mayLand(_router),
    );
    _passed.removeWhere((k) => !keys.contains(k));
    _completers.removeWhere((k, _) => !keys.contains(k));
    _reruns.removeWhere((k, _) => !keys.contains(k));

    if (!pushPath && shown != null && _guarded(shown)) {
      _schedule(shownKey!);
    }
    // Last, so what this judgment keeps is settled when the router answers it.
    if (leftWaiting) _cancelWaiting(config);
  }

  /// A question about the pushed page [key] is the person's (a pop, the back button, with a
  /// `leave()` to ask) while the re-run of its guard still waits: the re-run yields. Nothing is asked
  /// of the router here.
  ///
  /// - If the re-run lands while the page is still on the stack (the question is open, or was
  ///   refused), `leaveExit` refuses it ([guardRerunRefused]) and go_router replaces nothing: the
  ///   entry the answer is about stays that entry, so a yes finds it. A refusal keeps the page, which
  ///   is not checked again until its guard changes or the router shows it again.
  /// - If the page goes first, the commit that removes it cancels the re-run (see [_judge]).
  ///
  /// What the two rely on. go_router asks `onExit` of the pages the landing configuration removes
  /// from the one on screen, after the redirects of the re-run have answered, so the refusal can
  /// only reach a page that is still on the stack; a re-run that lands after its page went is asked
  /// of nobody, and the cancel is what stops it. Neither depends on the base's redirects being
  /// synchronous: the yield sends nothing, and the cancel is sent after the pop. A restore sent here
  /// instead, with the configuration that still holds the page, runs the base's redirect and puts
  /// the page back when an asynchronous one answers after the pop (the regression this replaces).
  /// Strict about the re-run being the router's request: a question that belongs to another request
  /// (a `go`, a browser's back) is asked inside that request, which dropped the re-run, and may not
  /// be refused.
  void _yield(String key) {
    final rerun = _reruns[key];
    if (rerun == null || !rerun.waiting || !rerun.current(_router)) return;
    rerun.yielded = true;
  }

  /// Cancels the navigation of a re-run that is still waiting for its guard, after its page went
  /// (see [_judge]): `restore` of [config], the configuration the person left, is a navigation of
  /// its own, the one `GoRouter.pop` makes after a pop, and the router drops the navigation that was
  /// on the way for the newer one. It commits nothing (the same configuration), and telemetry sees
  /// no navigation in it (the same location). Not in a build, where a router may not be asked to
  /// change: after the frame, which no event of the app comes before.
  ///
  /// What it relies on: [config] is the stack as it is now, so the restore can answer when it likes.
  /// With a synchronous base it has landed when `restore` returns, on the same list (go_router keeps
  /// the list it was given when the location is the same, so nothing is set and nothing commits).
  /// A base redirect that is asynchronous (several awaits) answers after the pop, and its answer is
  /// the stack the person left, which is the one on screen: nothing is put back. That holds because
  /// the restore is sent after the pop. Sent before it, with a configuration that still held the
  /// page, the same answer would put the page back (see [_yield]). A navigation that starts
  /// meanwhile (a `go`) replaces the restore as it replaces any pending navigation, and a restore
  /// that is issued later (after the frame) is skipped when the router has left [config] by then.
  void _cancelWaiting(RouteMatchList config) {
    void restore() {
      if (identical(_router.routerDelegate.currentConfiguration, config)) {
        _router.restore(config);
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => restore());
    } else {
      restore();
    }
  }

  /// Closes the routes without a page (dialogs, sheets) that lie over the pushed page [key], as the
  /// Navigator would if the page were removed: the routes over it on its own navigator, the tab's
  /// when it is in a tab, the root's when it is not. `replace` keeps the page key, so the Navigator
  /// would keep them, and they belong to the old page. What lies over the pages around it, a dialog
  /// the app opened on the root navigator over a page in a tab (`showDialog`'s default), is not over
  /// this page and stays, as it does when a base page of the tab moves. Not in a build, where a
  /// navigator may not be changed: after the frame.
  void _closeOver(List<RouteMatchBase> matches, String key) {
    final navigators = <GlobalKey<NavigatorState>>[];
    _navigatorsAround(matches, key, navigators);
    final own = navigators.isEmpty
        ? _router.routerDelegate.navigatorKey
        : navigators.last;
    void close() => own.currentState?.popUntil(_hasPage);

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => close());
    } else {
      close();
    }
  }

  /// The re-run that the redirect being run belongs to: the one whose navigation the router is on,
  /// null when the redirect is another navigation's.
  _Rerun? _rerunInFlight() {
    for (final rerun in _reruns.values) {
      if (rerun.current(_router)) return rerun;
    }
    return null;
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
  void _judgeNow() => _judge(_router.routerDelegate.currentConfiguration);

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

/// Whether [top], the pushed page on top of the configuration [router] just committed, was put there
/// by the navigation that the route information of [router] holds (a `push`, `pushReplacement` or
/// `replace`): the page's `Future` is that navigation's own.
///
/// The type of the information alone does not say so. It stays what the last request was until the
/// router reports the location it committed, and a request that has not landed yet keeps it: while
/// the re-run of a pushed page waits for its guard, the information is that re-run's `replace`, and
/// a pop the person makes meanwhile commits a stack that this request has nothing to do with. Taken
/// for a push, that commit would count the page it uncovers as one whose redirects have just passed,
/// and run nothing for it: a guard that turned to refuse while the page was covered would be missed,
/// and a page held back for its guard would be built. A page that a request put on top is told by the
/// completer it was made with, which go_router takes from the request (`ImperativeRouteMatch.completer`
/// is the request's own), so no other commit can have it.
bool _landedFromRequest(GoRouter router, ImperativeRouteMatch? top) {
  if (top == null) return false;
  final state = router.routeInformationProvider.value.state;
  if (state is! RouteInformationState) return false;
  return switch (state.type) {
    NavigatingType.push ||
    NavigatingType.pushReplacement ||
    NavigatingType.replace => identical(top.completer, state.completer),
    _ => false,
  };
}

/// Whether [router] is in a navigation that pushes a page (`push`, `pushReplacement` or `replace`):
/// the information it holds says so until the router reports the location it committed. A redirect
/// that runs now belongs to that navigation; for a commit see [_landedFromRequest].
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
/// `leaveExit` is asked about (since 0.21.0): null when this question is no part of a re-run, true
/// when it is the re-run landing and one of its redirects answered a location or failed (the page
/// moves, and `leave()` is asked as it is for a base page's redirect), false when it is the re-run
/// landing and the guards passed again (the page is replaced by itself, and nothing is asked).
///
/// A re-run is the navigation `replace` of the page with its own location. go_router asks the page
/// to leave when that navigation lands, after every redirect has answered: while a guard is still
/// asking, the page that goes (a pop, the back button) is the person's, and it is asked as it is with
/// no re-run. The re-run is in flight while the router's route information is the one that `replace`
/// put there, and a redirect that does not run through `runRedirect` is not seen, so such a re-run is
/// taken for one that passes.
bool? guardRerunMoves(GoRouter router, String pageKey) {
  final rerun = _guardsOf[router]?._reruns[pageKey];
  if (rerun == null || !rerun.current(router) || rerun.waiting) return null;
  return rerun.moves;
}

/// A question about the pushed page [pageKey] is the person's while the re-run of its guard waits:
/// the re-run yields (see `_RouterGuards._yield`). Nothing when no re-run waits.
void guardRerunYields(GoRouter router, String pageKey) =>
    _guardsOf[router]?._yield(pageKey);

/// Whether `leaveExit` refuses the landing of the re-run of the pushed page [pageKey] (since 0.21.0):
/// the re-run yielded to a question of the person's about the page (see `_RouterGuards._yield`), and
/// its guards have answered since, so go_router is about to replace the entry that question is about.
/// Refused, the replace changes nothing. False for a question of the person's, which is asked while a
/// guard still waits, and for any page whose re-run did not yield.
///
/// A guard that refuses is not ignored because nobody asked the page. When the landing would have
/// moved it (a redirect answered a location, or failed), refusing it also asks for the re-run again,
/// on the frame after the refusal (see `_RouterGuards._askAgain`): the question is settled by then,
/// and the landing is asked about as the move it is, so the person is asked again (and may refuse
/// again, which ends it: nothing asks a third time by itself), or the page moves. A landing that
/// passes needs nothing more. A question that is still open then is the one the new landing joins.
///
/// A question that arrives between the last guard's answer and the end of the frame in which the
/// router reports the configuration it kept (a few microtasks, then one frame) is taken for the
/// landing, and refused without being asked: the person presses again, and so does an app's own
/// `pop()` in that window. The flag is not cleared when it refuses, because a question that was
/// taken for a landing that passes (see [guardRerunMoves]) is let through without being asked, which
/// loses input; a refusal is the safe side.
bool guardRerunRefused(GoRouter router, String pageKey) {
  final guards = _guardsOf[router];
  final rerun = guards?._reruns[pageKey];
  if (rerun == null ||
      !rerun.yielded ||
      !rerun.current(router) ||
      rerun.waiting) {
    return false;
  }
  // A guard that refuses is not ignored because nobody asked the page: when the landing would have
  // moved it, the re-run goes again, and its landing is asked about as the move it is.
  if (rerun.moves) guards!._askAgain(pageKey);
  return true;
}

/// Whether [info], the route information [router] holds, is the `replace` of a guard's re-run (see
/// `_RouterGuards._rerun`) and not one the app made: it asks for no change of the page, so it says
/// nothing about a page that goes meanwhile.
bool isGuardRerun(GoRouter router, Object? info) {
  final guards = _guardsOf[router];
  return guards != null &&
      guards._reruns.values.any((r) => identical(r.info, info));
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

  /// Whether a question of the person's about the page came while the re-run waited for a guard: when
  /// the re-run lands, it is refused (see [guardRerunRefused]).
  bool yielded = false;

  /// How many of its redirects have not answered yet (a guard that takes a while): the navigation of
  /// go_router that the re-run is has not landed, and will when they have.
  int pending = 0;

  /// Whether the re-run still waits for a guard.
  bool get waiting => pending > 0;

  /// Whether the router is still on the navigation of this re-run.
  bool current(GoRouter router) =>
      info == null || identical(info, router.routeInformationProvider.value);

  /// Whether the navigation of this re-run may still land: [current], or the route information was
  /// reported in its place (the router reports what it showed, which is not a request).
  bool mayLand(GoRouter router) =>
      current(router) ||
      router.routeInformationProvider.value.state is! RouteInformationState;
}

/// One evaluation of a guard site and its subscription.
final class _Live {
  _Live(this.context, {this.owner});

  /// The router's guards, told when an evaluation starts and ends.
  final _RouterGuards? owner;

  /// The page key of the pushed page this guard is bound to (since 0.21.0), null for the base: the
  /// guard runs again on that page while it is on top.
  ///
  /// A site belongs to one page, the last that evaluated it. A route nested under a guarded parent
  /// shares the parent's site: a push of the child evaluates it again, and that evaluation replaces
  /// the base's, bound to the pushed page when the push commits. That is harmless. The ping of a
  /// site bound to a pushed page refreshes the router when the base is under a redirect, and a base
  /// that shares the guard is under one, so the base's redirect runs in the refresh whichever page
  /// the site is bound to; when the base is under none, the site was never its own. When the pushed
  /// page goes, the commit closes the site (its page is gone), and the base's guard is watched again
  /// when a navigation evaluates it, as for any page that was pushed over the base.
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
  _Rerun? rerun;
  if (router is GoRouter) {
    var guards = _guardsOf[router];
    if (guards == null && _isPushNavigation(router)) {
      guards = _guardsOf[router] = _RouterGuards(router);
    }
    // Only a redirect that belongs to the re-run of a pushed page needs a word to the router.
    rerun = guards?._rerunInFlight();
  }
  if (router != null &&
      parent != null &&
      parent[_goRouterZoneKey] == null &&
      !zone.inSameErrorZone(parent)) {
    return parent
        .fork(zoneValues: {_goRouterZoneKey: router})
        .run(() => _redirect(redirect, rerun));
  }
  return _redirect(redirect, rerun);
}

/// Runs [redirect] for [runRedirect]. When [rerun] is given, the redirect belongs to the re-run of a
/// pushed page: an answer that moves the page (a location, or a failure) is told to it, as is a guard
/// that has not answered yet. `leave()` is asked only of a page that a re-run moves, and a question
/// about the page while a guard waits is the person's (see [guardRerunMoves]).
FutureOr<String?> _redirect(GuardResult Function() redirect, _Rerun? rerun) {
  final GuardResult result;
  try {
    result = redirect();
  } catch (error, stackTrace) {
    final failure = _failure(error, stackTrace);
    rerun?.moves = true;
    Error.throwWithStackTrace(failure, failure.stackTrace);
  }
  if (result is! Future<String?>) {
    if (result != null) rerun?.moves = true;
    return result;
  }
  if (rerun == null) return result.then<String?>(_same, onError: _fail);
  rerun.pending++;
  return result.then<String?>(
    (location) {
      rerun.pending--;
      if (location != null) rerun.moves = true;
      return location;
    },
    onError: (Object error, StackTrace stackTrace) {
      rerun.pending--;
      rerun.moves = true;
      _fail(error, stackTrace);
    },
  );
}

/// Fails a redirect that failed after it answered `Future`: with a [GuardFailure].
Never _fail(Object error, StackTrace stackTrace) {
  final failure = _failure(error, stackTrace);
  Error.throwWithStackTrace(failure, failure.stackTrace);
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
/// The failure reaches the error route in one of two places.
///
/// - After `go`, a link or the first location, it is the router's own error, and the retry calls
///   `GoRouter.refresh`, which runs the navigation again.
/// - After `push`, and `pushReplacement` and `replace` over other pages, go_router puts the failed
///   list in an entry on top of the stack, and the router's own `error` stays null. Since 0.21.0 the
///   retry replaces that entry with a navigation to the same location and `extra`, which keeps the
///   entry's page key: the guard runs again, and a page that passes shows in the entry's place. The
///   `Future` of the `push` that failed completes with the result of the page in its place when that
///   page pops (`null` when it is popped without one). A dialog, a sheet or another route without a
///   page over the error view is closed first, so the retry replaces the error view and not the
///   dialog.
///
/// A retry held after the router moved on (the entry closed, another page above it) does nothing.
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
