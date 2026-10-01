import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

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
/// the error reaches go_router on a navigation, as a guard's errors always have.
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

  /// The sites evaluated since the router last committed a location.
  final _touched = <String>{};

  FutureOr<String?> run(
    BuildContext context,
    ProviderContainer container,
    String site,
    GuardResult Function(Ref ref) guard,
  ) {
    final live = _Live(context);
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
    _router.refresh();
  }

  /// The router committed a location: guards it did not run are not its any more.
  void _committed() {
    final stale = [
      for (final site in _live.keys)
        if (!_touched.contains(site)) site,
    ];
    for (final site in stale) {
      _live.remove(site)?.close();
    }
    _touched.clear();
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
  _Live(this.context);

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
        });
  }

  /// Closes the subscription, but not under an evaluation still awaiting: its `ref`
  /// would be disposed under it, and a `ref.watch` after an `await` would throw.
  void close() {
    _closing = true;
    if (_pending == 0) sub?.close();
  }
}
