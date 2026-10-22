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
/// pushed it: the router builds nothing for it (`refusedView`).
///
/// **Identity comes only from go_router's own objects.** An entry is known by its
/// `ImperativeRouteMatch.completer`, a navigation by the `RouteInformationState` it put in the
/// route information provider (its completer is the one of the entry the navigation puts on the
/// stack). There is no listener on that provider, no zone of our own, no count of notifications, no
/// timer and no new microtask: the only deferred work is post-frame callbacks. What was tried
/// before (the provider's value, the notifications, a zone, a copy of the last request) failed in
/// six reviews, each time by leaking one navigation's identity into another.
///
/// The invariants, each pinned by test/pushed_guard_test.dart or test/leave_test.dart:
///
/// 1. A site is owned by the entry whose navigation evaluated it (or by the base), and the first
///    commit that shows another entry on top closes it.
/// 2. A commit is a push only when its top entry's completer belongs to a request whose redirects
///    ran: the request the provider holds at the commit, or one stored in [_requests].
/// 3. A guarded pushed page whose key passed no push commit is never built, never entered, and
///    never asked `leave()`.
/// 4. A guarded pushed page shown by any other commit is re-run once, after the frame, if it is
///    still on top.
/// 5. [_landing] lives exactly as long as [_rerun]'s synchronous `replace` call, so no callback
///    registered during that call can see it.
/// 6. A redirect, a site or a `leave()` question belongs to a re-run only if the provider's request
///    is the re-run's own and, for `leave()`, the leaving entry is the re-run's entry.
/// 7. An asynchronous re-run never lands: at its first asynchronous answer it is dropped, and
///    carried on only while its entry is on top.
/// 8. A re-run's landing has all its answers when `leave()` is asked: a pass asks nothing, a move
///    asks with no exemption.
/// 9. Every re-run's request is recorded before its landing is judged, so a landing never
///    schedules another re-run.
/// 10. The push's `Future` answers to the completer of the last push commit of its page key.
/// 11. There is no provider listener, no timer and no new microtask; only post-frame callbacks.
final class _RouterGuards {
  _RouterGuards(this._router) {
    // The delegate only (invariant 11): the commit is what this class reads, and the request that
    // is on the way is read from the provider's value when it is needed.
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

  /// The pushed pages whose redirects passed in a push commit, by page key (invariant 3): a page
  /// with a redirect that is not here is held back ([refuses]). Keyed by page key, not by
  /// completer, because a refresh decodes every pushed entry with a new completer and keeps its
  /// key, and so keeps the page's state.
  final _passed = <String>{};

  /// The completer each pushed page's `Future` answers to (invariant 10): the one of the last push
  /// commit of the page key that was not a re-run's. A re-run forwards its own result there, so the
  /// `Future` completes when the page that stands in for the first one pops, also after a refresh
  /// gave the entry a completer nobody awaits.
  final _completers = <String, Completer<Object?>>{};

  /// The pages whose re-run is scheduled for after the frame (invariant 4): one at a time.
  final _scheduled = <String>{};

  /// The configuration the last judgment was made for: one judgment per configuration object.
  RouteMatchList? _judged;

  /// The re-run whose `router.replace` call is on the stack, null at any other time (invariant 5).
  /// It is set before the call and cleared in a `finally`, so it is not there for a callback that
  /// is registered during the call and runs after it, a microtask, a timer, a listener included.
  _Rerun? _landing;

  /// The push-type requests whose redirects ran, by the completer of their entry (invariant 2): a
  /// commit whose top entry has such a completer is the landing of that request, whether or not the
  /// provider still holds it (the router's report replaces the provider's value after a commit,
  /// and a request that waits for an asynchronous redirect lands later). `runRedirect` stores the
  /// request it sees, [_rerun] stores its own right after `replace` returns (invariant 9), and the
  /// landing clears it. A pop back to the entry is then no landing: its completer is not here any
  /// more.
  final _requests = Expando<_Request>('fespalier push requests');

  FutureOr<String?> run(
    BuildContext context,
    ProviderContainer container,
    String site,
    GuardResult Function(Ref ref) guard,
  ) {
    this.container = container;
    final live = _Live(context, guards: this);
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
    // Whose evaluation is this (invariants 1 and 6)? A guard evaluated for the re-run of a pushed
    // page belongs to that page from the start: `replace` keeps the page key, and the navigation
    // may end without a commit (a `leave()` that refuses the move, a guard that never answers),
    // after which nothing would tell where the guard stood. It may also be evaluated after the
    // call, in the continuation of a guard before it, while the provider still holds the request.
    // Any other navigation says which page it puts on top when it commits.
    final request = _pushRequest();
    final rerun = request == null ? null : _rerunOf(request);
    if (rerun != null) {
      live.owner = rerun.entry.completer;
      live.fresh = false;
    } else {
      live.request = request?.completer;
    }
    // The new subscription is open before the old one closes, so the providers both
    // watch are not disposed and fetched again in between.
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
    if (_landing == null) {
      _act(site, live);
      return;
    }
    // Inside a re-run's `replace` call (invariant 5): no navigation can start here, go_router would
    // start it inside its own. After the frame.
    SchedulerBinding.instance.addPostFrameCallback((_) => _act(site, live));
  }

  /// A guard's answer changed: the router asks again, in the way that fits the site's owner.
  void _act(String site, _Live live) {
    if (!identical(_live[site], live)) return;
    final hook = guardRefreshHooks[_router];
    final owner = live.owner;
    // A guard of a pushed page: the page is run again, and only while its entry is on top.
    final top = owner == null ? null : _topEntry();
    if (owner != null &&
        (top == null ||
            !identical(top.completer, owner) ||
            top.matches.isError)) {
      _live.remove(site)?.close();
      return;
    }

    // go_router restores the pages under the one on top without their redirects, so a base page that
    // is under a redirect must be asked again too, whichever site pinged: a sign-out that only moved
    // the top page would leave the base under it, and the system back would land on it signed out.
    // `refresh()` asks the base. When its redirect moves it, the whole stack is replaced, as it was
    // before the pushed page's guard watched anything (before 0.21.0). When it keeps its place, the
    // commit of the refresh shows the pushed page as a restored one, and it runs its guard again after
    // the frame (invariant 4). A base under no redirect has nothing to ask, so the pushed page alone is
    // run again, at once.
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

  /// The `RouteInformationState` of the push-type navigation (`push`, `pushReplacement` or
  /// `replace`) that the provider holds now, null when it holds anything else: a `go`, a restore, a
  /// platform report, or the router's own report of what it committed (an encoded `Map`).
  RouteInformationState<Object?>? _pushRequest() =>
      _pushRequestOf(_router.routeInformationProvider.value);

  /// The re-run that [request] is, or null when it is any other navigation (invariant 6). Inside
  /// the `replace` call of a re-run the request is told by being the one `replace` just put in the
  /// provider (see [_Rerun.adopt]); after the call, by the entry [_rerun] stored for it.
  _Rerun? _rerunOf(RouteInformationState<Object?> request) {
    final landing = _landing;
    if (landing != null &&
        identical(landing.request ??= landing.adopt(request), request)) {
      return landing;
    }
    final completer = request.completer;
    return completer == null ? null : _requests[completer]?.rerun;
  }

  /// Runs the guard of the pushed page [entry] again, as a navigation that replaces the page with
  /// the same location and `extra`: go_router runs the redirects of the entry, keeps its page key
  /// and leaves the stack below alone. The `Future` of that navigation completes the completer the
  /// page answers to (see [_completers], invariant 10).
  ///
  /// The call is synchronous when every guard answers at once, and then the landing is in it. An
  /// asynchronous guard drops the re-run at its first answer (invariant 7, see [_carry]).
  ///
  /// `leave()` is asked of the page only when it moves it (see [guardRerunVerdict]).
  void _rerun(ImperativeRouteMatch entry, [_Rerun? dropped]) {
    final key = entry.pageKey.value;
    if (_landing != null) {
      // Inside another re-run's call (invariant 5).
      _schedule(key);
      return;
    }
    final target = _completers[key] ?? entry.completer;
    final rerun = _Rerun(
      this,
      entry,
      base: _router.routerDelegate.currentConfiguration,
      before: _router.routeInformationProvider.value.state,
      zone: Zone.current,
      replay: dropped?.answers ?? const [],
    );
    _landing = rerun;
    final Future<Object?> answer;
    try {
      answer = _router.replace<Object?>(
        entry.matches.uri.toString(),
        extra: entry.matches.extra,
      );
    } finally {
      _landing = null;
    }
    // Recorded before anything can land it later (invariant 9). A landing in the call has cleared
    // it already ([_judge] sets `landed`).
    final request = _pushRequest();
    if (request != null && !rerun.landed) {
      rerun.request ??= rerun.adopt(request);
      final completer = request.completer;
      if (completer != null && identical(rerun.request, request)) {
        _requests[completer] = _Request(rerun);
      }
    }
    answer.then<void>(
      (value) => _completeWith(target, value),
      onError: (Object error, StackTrace stack) {
        if (!target.isCompleted) target.completeError(error, stack);
      },
    );
  }

  /// An asynchronous re-run answered its first asynchronous redirect (invariant 7): go_router
  /// must not land it. The `Future` it gets never completes, so it never lands, and its `replace`
  /// `Future` never completes either.
  ///
  /// If the entry it was about is still on top (the same completer), the re-run goes on as a new
  /// one that replays the answers received so far by position, so every redirect answers at once
  /// and the new `replace` lands in its own call, with all its answers (invariant 8). It starts in
  /// the zone the first re-run started in, so it does not inherit the error zone go_router
  /// 17.2.3 to 18.1.0 run a redirect in. If the entry has gone (a pop, a `go`, a refresh that gave
  /// the page a new completer, another re-run that landed), nothing is carried and nothing comes
  /// back: the person's pop is not undone by a guard that answers late.
  Future<String?> _carry(_Rerun dropped) {
    final top = _topEntry();
    if (top != null && identical(top.completer, dropped.entry.completer)) {
      dropped.zone.run(() => _rerun(top, dropped));
    }
    return Completer<String?>().future;
  }

  /// Runs the re-run of the pushed page [key] after the frame, once, when it is still on top then
  /// and shows a page (invariant 4).
  ///
  /// In a post-frame callback and nowhere else: a navigation started inside the commit that asks for
  /// it would start inside go_router's own, and there is no timer and no microtask (invariant 11).
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

  /// The router committed a location: the navigation's sites are bound to the page it put on top,
  /// the rest are no longer watched. See [_judge].
  void _committed() => _judgeNow();

  /// Judges the committed [config] once (since 0.21.0). The commit is a push when its top entry
  /// was put there by a request whose redirects ran ([_requestThatPut]): that page passed or failed
  /// them. Any other commit (a refresh, a restore, a pop back, a tab, a swap) shows a page whose
  /// redirects did not run.
  ///
  /// - A failed commit closes every site: a page that never showed has nothing to keep up to date (a
  ///   refresh that one of them asked for would show the guarded page, #258).
  /// - A site evaluated by a navigation (not a re-run) is bound to the top entry when its request is
  ///   the one that put the entry there, and to the base when the navigation made no request. A site
  ///   of a request that did not put the top entry there is closed (invariant 1).
  /// - A site bound to an entry stays while that entry is on top, and is closed as soon as another
  ///   entry, or none, is. A site bound to the base stays only for the commit of the navigation that
  ///   evaluated it, as before 0.21.0: a guarded page under a pushed page waits for the pop. A change
  ///   only the pushed page's guard notices asks the base with a refresh when the base is under a
  ///   redirect (see [_act]).
  /// - A re-run's landing moves the sites of the entry it replaced to the entry it put there (the
  ///   page key is the same). The sites that answered a location are closed when a push or a re-run
  ///   puts its page on top: a guard that sent the page elsewhere does not belong to it.
  /// - A pushed page that is on top and was not put there by a push runs its guard again, after the
  ///   frame (invariant 4).
  void _judge(RouteMatchList config) {
    if (identical(config, _judged)) return;
    _judged = config;
    final pushed = <ImperativeRouteMatch>[];
    pushedMatches(config.matches, pushed);
    final failed = activeMatches(config, pushed).error is GuardFailure;
    final top = pushed.isEmpty ? null : pushed.last;
    final topCompleter = top?.completer;
    final request = _requestThatPut(top);
    final rerun = request?.rerun;
    final shown = top != null && !top.matches.isError ? top : null;
    final shownKey = shown?.pageKey.value;
    final replaced = rerun?.entry.completer;

    final stale = <String>[];
    for (final MapEntry(key: site, value: live) in _live.entries) {
      if (failed) {
        stale.add(site);
        continue;
      }
      if (live.fresh) {
        live.fresh = false;
        final from = live.request;
        live.request = null;
        if (from == null || top == null) {
          // The base's: a navigation that made no request, or a `replace` or `pushReplacement` that
          // left no pushed page (go_router gives a plain list when the page it replaced was the
          // base's).
          live.owner = null;
        } else if (identical(from, topCompleter)) {
          live.owner = topCompleter;
        } else {
          stale.add(site);
          continue;
        }
      } else if (replaced != null && identical(live.owner, replaced)) {
        live.owner = topCompleter;
      } else if (live.owner == null || !identical(live.owner, topCompleter)) {
        stale.add(site);
        continue;
      }
      // A guard that sent the page elsewhere does not belong to it: the page that stands in its place
      // is another route's, and (`replace` keeps the page key) it would be run again, as a navigation
      // of its own, whenever the guard changed back. The guards of the location it moved to (they
      // passed) stay.
      if (request != null && live.owner != null && live.redirected) {
        stale.add(site);
      }
    }
    for (final site in stale) {
      _live.remove(site)?.close();
    }

    if (request != null && top != null) {
      final key = top.pageKey.value;
      if (top.matches.isError) {
        _passed.remove(key);
      } else {
        _passed.add(key);
      }
      // A re-run's own commit keeps the completer the caller holds; any other commit is the
      // caller's navigation, and its completer is the one to answer (invariant 10).
      if (rerun == null) {
        _completers[key] = top.completer;
      } else if (top.matches.isError || top.matches.uri != rerun.uri) {
        // The page moved, or its guard failed: `replace` keeps the page key, so the Navigator keeps
        // the dialogs and sheets over it, and they are the old page's.
        _closeOver(config.matches, key);
      }
      // Landed: a later commit with this entry (a pop back to it) is no landing (invariant 2).
      _requests[top.completer] = null;
      rerun?.landed = true;
    }
    final keys = {for (final e in pushed) e.pageKey.value};
    _passed.removeWhere((k) => !keys.contains(k));
    _completers.removeWhere((k, _) => !keys.contains(k));

    if (request == null && shown != null && _guarded(shown)) {
      _schedule(shownKey!);
    }
  }

  /// The push request whose landing the commit with [top] on top is (invariant 2): the one the
  /// provider holds when its entry has the completer of [top], else the one [_requests] has for it.
  /// Null when the commit is no landing of a request whose redirects ran.
  _Request? _requestThatPut(ImperativeRouteMatch? top) {
    if (top == null) return null;
    final held = _pushRequest();
    if (held != null && identical(held.completer, top.completer)) {
      return _Request(_rerunOf(held));
    }
    return _requests[top.completer];
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

/// The `RouteInformationState` of the push-type navigation (`push`, `pushReplacement` or `replace`)
/// that [info], the route information of a router's provider, holds; null for anything else.
RouteInformationState<Object?>? _pushRequestOf(RouteInformation info) {
  final state = info.state;
  if (state is! RouteInformationState<Object?> || state.completer == null) {
    return null;
  }
  return switch (state.type) {
    NavigatingType.push ||
    NavigatingType.pushReplacement ||
    NavigatingType.replace => state,
    NavigatingType.go || NavigatingType.restore => null,
  };
}

/// Whether the landing that `leaveExit` is asked about moves the pushed page [pageKey] (since
/// 0.21.0): null when this question is no part of a guard's re-run (the person's, the app's, a
/// refresh's), true when it is a re-run's landing and one of its redirects answered a location or
/// failed (the page moves, and `leave()` is asked as it is for a base page's redirect), false when
/// it is a re-run's landing and the guards passed again (the page is replaced by itself, and nothing
/// is asked).
///
/// A re-run is the navigation `replace` of the page with its own location. go_router asks the page
/// to leave when that navigation lands, after every redirect has answered. A re-run lands in its own
/// synchronous call (invariant 8: an asynchronous one is carried on by one that replays the answers,
/// see [_RouterGuards._carry]), so every redirect has answered when this is asked, and the question
/// is the re-run's when it is asked inside that call (invariant 5), the provider holds the re-run's
/// own request (invariant 6) and the entry that leaves is the one the re-run replaces. A question
/// from anywhere else (the person's press, an app's own `pop()`, however soon after the last guard
/// answered) is not, so it is asked as usual. A redirect that does not run through `runRedirect` is
/// not seen, so such a re-run is taken for one that passes.
bool? guardRerunVerdict(GoRouter router, ValueKey<String> pageKey) {
  final guards = _guardsOf[router];
  final rerun = guards?._landing;
  if (guards == null || rerun == null) return null;
  final request = guards._pushRequest();
  if (request == null || !identical(guards._rerunOf(request), rerun)) {
    return null;
  }
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(router.routerDelegate.currentConfiguration.matches, pushed);
  for (final entry in pushed) {
    if (entry.pageKey == pageKey) {
      return identical(entry.completer, rerun.entry.completer)
          ? rerun.moves
          : null;
    }
  }
  return null;
}

/// Whether [state], the `RouteInformationState` of the route information [router] holds, is the
/// `replace` of a guard's re-run (see `_RouterGuards._rerun`) and not one the app made: it asks for
/// no change of the page, so it says nothing about a page that goes meanwhile.
bool isGuardRerun(GoRouter router, Object? state) {
  final guards = _guardsOf[router];
  if (guards == null || state is! RouteInformationState<Object?>) return false;
  return guards._rerunOf(state) != null;
}

/// Whether [entry], a pushed page of [router], is held back (see `_RouterGuards._held`): it is a
/// page the walk of `RouterWatch` treats as an error view, which covers the page below it.
bool refusedEntry(GoRouter router, ImperativeRouteMatch entry) =>
    _guardsOf[router]?.refusesEntry(entry) ?? false;

/// One re-run of a pushed page's guard (see [_RouterGuards._rerun]).
final class _Rerun {
  _Rerun(
    this.guards,
    this.entry, {
    required this.base,
    required this.before,
    required this.zone,
    required this.replay,
  }) : uri = entry.matches.uri;

  /// The guards of the router the re-run is on.
  final _RouterGuards guards;

  /// The pushed page the re-run replaces: its completer is the entry's identity.
  final ImperativeRouteMatch entry;

  /// The page's location before the re-run: the page moved when the commit shows another one.
  final Uri uri;

  /// The configuration `replace` is given, and what the provider held before it: the request that
  /// `replace` puts in the provider is told by being new and made from [base] ([adopt]).
  final RouteMatchList base;
  final Object? before;

  /// The zone the re-run started in, which a carried one starts in too (see
  /// [_RouterGuards._carry]).
  final Zone zone;

  /// The answers of the redirects of a re-run this one carries on, by position: each answers at
  /// once. A location (or null), or a [GuardFailure].
  final List<Object?> replay;

  /// The answers of this re-run's redirects by position, replayed ones included.
  final answers = <Object?>[];

  /// The `RouteInformationState` the `replace` of the re-run put in the router's provider: the
  /// identity of its navigation, whose completer is the one of the page it puts on the stack. Null
  /// until the first redirect, a site, a question or the end of the call has asked for it
  /// ([adopt]).
  RouteInformationState<Object?>? request;

  /// Whether a redirect of the re-run answered a location or failed: the landing moves the page.
  bool moves = false;

  /// Whether the re-run's request landed (the router committed the entry that carries its
  /// completer).
  bool landed = false;

  /// The position of the next redirect of the re-run (the redirects of a navigation run in order).
  int position = 0;

  /// [state], the provider's value, when it is the request `replace` just put there: a new request
  /// that replaces an entry, made from the configuration this re-run gave it. Null otherwise (invariant
  /// 6).
  RouteInformationState<Object?>? adopt(RouteInformationState<Object?> state) =>
      !identical(state, before) &&
          state.type == NavigatingType.replace &&
          identical(state.baseRouteMatchList, base)
      ? state
      : null;

  /// Records the answer of the redirect at the next position: a location (or null), or a
  /// [GuardFailure].
  void record(Object? answer) {
    answers.add(answer);
    if (answer != null) moves = true;
  }
}

/// A push-type request whose redirects ran (see [_RouterGuards._requests]).
final class _Request {
  _Request(this.rerun);

  /// The re-run that made it, null for a `push`, `pushReplacement` or `replace` of the app's.
  final _Rerun? rerun;
}

/// One evaluation of a guard site and its subscription.
final class _Live {
  _Live(this.context, {this.guards});

  /// The router's guards, told when an evaluation starts and ends.
  final _RouterGuards? guards;

  /// The completer of the pushed entry this guard belongs to (since 0.21.0), null for the base (and
  /// for a guard whose navigation has not committed yet, see [fresh]): the guard runs again on that
  /// page while the entry is on top (invariant 1).
  ///
  /// A site belongs to one entry, the last that evaluated it. A route nested under a guarded parent
  /// shares the parent's site: a push of the child evaluates it again, and that evaluation replaces
  /// the base's, bound to the pushed entry when the push commits. That is harmless. The ping of a
  /// site bound to a pushed entry refreshes the router when the base is under a redirect, and a base
  /// that shares the guard is under one, so the base's redirect runs in the refresh whichever entry
  /// the site is bound to; when the base is under none, the site was never its own. When the pushed
  /// page goes, the commit closes the site (its entry is gone), and the base's guard is watched again
  /// when a navigation evaluates it, as for any page that was pushed over the base.
  Completer<Object?>? owner;

  /// The completer of the push-type request the guard was evaluated under (the entry that request
  /// puts on the stack has it), until the commit that binds the guard to its entry, or closes it.
  /// Null when the navigation made no request, and for a re-run's guard, which belongs to its entry
  /// from the start.
  Completer<Object?>? request;

  /// Whether the guard was evaluated by a navigation that has not committed yet: the next commit
  /// binds it ([_RouterGuards._judge]).
  var fresh = true;

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

  /// Whether the answer the navigation used was a location: the guard sent the page elsewhere.
  bool get redirected => _usedKnown && _used != null;

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
    guards?._evaluating(1);
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
          guards?._evaluating(-1);
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
    final request = _pushRequestOf(router.routeInformationProvider.value);
    if (request != null) {
      final guards = _guardsOf[router] ??= _RouterGuards(router);
      final own = guards._rerunOf(request);
      // Only a redirect that runs inside the re-run's own call needs a word to the router
      // (invariants 5 and 6); the request is recorded here for any other (invariant 2).
      if (own != null) {
        if (identical(own, guards._landing)) rerun = own;
      } else {
        guards._requests[request.completer!] ??= _Request(null);
      }
    }
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
/// pushed page, and runs in its `replace` call: its answer is recorded by position, and an answer
/// that moves the page (a location, or a failure) is told to the landing ([guardRerunVerdict]). A
/// redirect whose position the re-run has an answer for (it carries on a dropped one) answers at
/// once with that. One that answers with a `Future` drops the re-run when the `Future` completes
/// (invariant 7, see [_RouterGuards._carry]).
FutureOr<String?> _redirect(GuardResult Function() redirect, _Rerun? rerun) {
  if (rerun != null) {
    final position = rerun.position++;
    if (position < rerun.replay.length) {
      final answer = rerun.replay[position];
      rerun.record(answer);
      if (answer is GuardFailure) {
        Error.throwWithStackTrace(answer, answer.stackTrace);
      }
      return answer as String?;
    }
  }
  final GuardResult result;
  try {
    result = redirect();
  } catch (error, stackTrace) {
    final failure = _failure(error, stackTrace);
    rerun?.record(failure);
    Error.throwWithStackTrace(failure, failure.stackTrace);
  }
  if (result is! Future<String?>) {
    rerun?.record(result);
    return result;
  }
  if (rerun == null) return result.then<String?>(_same, onError: _fail);
  final guards = rerun.guards;
  return result.then<String?>(
    (location) {
      rerun.record(location);
      return guards._carry(rerun);
    },
    onError: (Object error, StackTrace stackTrace) {
      rerun.record(_failure(error, stackTrace));
      return guards._carry(rerun);
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
