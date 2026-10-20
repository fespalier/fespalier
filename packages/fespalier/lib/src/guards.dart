import 'dart:async';

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

/// The guards of one router that stay subscribed: one per guard site (a route and
/// a guard on it), replaced when that site runs again.
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
    if (hook == null) {
      _router.refresh();
    } else {
      hook(_router.refresh);
    }
  }

  /// The router committed a location: guards it did not run are not its any more. When what it
  /// committed is a guard that failed (since 0.21.0), the guards that navigation did run are not
  /// its either: a page that never showed has nothing to keep up to date, and a refresh that one of
  /// them asked for after a pushed failure would show the guarded page without running its guard
  /// (go_router's own gap, fespalier/fespalier#258).
  void _committed() {
    final failed = _failed();
    final stale = [
      for (final site in _live.keys)
        if (failed || !_touched.contains(site)) site,
    ];
    for (final site in stale) {
      _live.remove(site)?.close();
    }
    _touched.clear();
  }

  /// Whether the router shows a guard that failed: its own error (after `go`, a link or a tab), or
  /// the failed list in the entry on top of the stack (after `push`, and `pushReplacement` and
  /// `replace` over other pages).
  bool _failed() {
    final config = _router.routerDelegate.currentConfiguration;
    final pushed = <ImperativeRouteMatch>[];
    pushedMatches(config.matches, pushed);
    return activeMatches(config, pushed).error is GuardFailure;
  }

  void _closeAll() {
    for (final live in _live.values) {
      live.close();
    }
    _live.clear();
    _touched.clear();
  }
}

/// One evaluation of a guard site and its subscription.
final class _Live {
  _Live(this.context, {this.owner});

  /// The router's guards, told when an evaluation starts and ends.
  final _RouterGuards? owner;

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
  if (router != null &&
      parent != null &&
      parent[_goRouterZoneKey] == null &&
      !zone.inSameErrorZone(parent)) {
    return parent
        .fork(zoneValues: {_goRouterZoneKey: router})
        .run(() => _redirect(redirect));
  }
  return _redirect(redirect);
}

FutureOr<String?> _redirect(GuardResult Function() redirect) {
  final GuardResult result;
  try {
    result = redirect();
  } catch (error, stackTrace) {
    final failure = _failure(error, stackTrace);
    Error.throwWithStackTrace(failure, failure.stackTrace);
  }
  if (result is! Future<String?>) return result;
  return result.then<String?>(
    _same,
    onError: (Object error, StackTrace stackTrace) {
      final failure = _failure(error, stackTrace);
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
/// entry and pushes the same location with the same `extra` again. The `Future` of the `push` that
/// failed completes with `null` when the retry closes the entry, as it does when the user does; the
/// page the retry pushes has no `Future` of its own that anyone waits for. A retry held after the
/// router moved on (the entry closed, another page above it) does nothing.
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
  void retry() {
    if (router != null) _retry(router, failure);
  }

  return guardError?.call(
        state.uri,
        failure.error,
        failure.stackTrace,
        retry,
      ) ??
      notFound(state.uri);
}

/// Runs again the navigation that failed with [failure], if the router still shows it: see
/// [routerErrorPage].
void _retry(GoRouter router, GuardFailure failure) {
  final config = router.routerDelegate.currentConfiguration;
  if (identical(config.error, failure)) {
    router.refresh();
    return;
  }
  // A pushed navigation: go_router keeps its failed list in the entry it pushed, which is the
  // page on top (the last pushed entry, however deep in the shells) while the error view shows.
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(config.matches, pushed);
  if (pushed.isEmpty || !identical(pushed.last.matches.error, failure)) return;
  if (!router.canPop()) return;
  final failed = pushed.last.matches;
  router.pop();
  unawaited(router.push<Object?>(failed.uri.toString(), extra: failed.extra));
}
