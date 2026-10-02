import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart'
    show NotifierProviderFamily, ProviderListenable, ProviderOrFamily;

import 'devtools/devtools.dart'
    show kFespalierDevTools, traceActionEnd, traceActionStart;

/// The provider of one function of an `action.dart`: what the generated
/// `XRoute.action` (or `XRoute.approveAction`, ...) is, called with the action's keys when
/// it has any.
///
/// Its state is `AsyncValue<T?>`: `AsyncData(null)` before the first run (idle),
/// `AsyncLoading` while one runs, `AsyncError` when the last run failed and `AsyncData` of
/// the result when it succeeded. It works without a widget: read `.notifier` from a
/// `ProviderContainer` and call [ActionNotifier.call].
typedef ActionProvider<I, T> =
    NotifierProvider<ActionNotifier<I, T>, AsyncValue<T?>>;

/// Runs one function of an `action.dart` and holds its state.
///
/// A write is never retried: one that failed stays failed until it is called again. After
/// a success it invalidates the data the action made stale (the route's own `data.dart` and
/// the sections' above it, or what `invalidates` lists), so the page shows what the server
/// says now.
///
/// The notifier lives for as long as a run is in flight, even when nothing watches it, so a
/// page that goes away while a submission is pending does not cancel the write, and the
/// result of a run that finishes after the page is gone is dropped without a trace: the
/// state is only written while the provider is alive.
final class ActionNotifier<I, T> extends Notifier<AsyncValue<T?>> {
  /// Creates the notifier for [_run], invalidating what [_invalidates] lists after a success.
  /// The generated file builds one per key through [actionProvider] or [actionFamily]; an app
  /// has no reason to.
  ///
  /// [site] and [key] say which action this is to the DevTools extension (since 0.7.0); they
  /// are only kept in a build that has it.
  ActionNotifier(this._run, this._invalidates, {String? site, Object? key})
    : _site = kFespalierDevTools ? site : null,
      _key = kFespalierDevTools ? key : null;

  final FutureOr<T> Function(Ref ref, I input) _run;
  final Iterable<ProviderListenable<AsyncValue<Object?>>> Function()
  _invalidates;

  /// The action's key in the tree's `sites` and the family's key, for DevTools; null in a build
  /// without it.
  final String? _site;
  final Object? _key;

  /// Counts the runs, so that only the last one started (or [reset]) writes the state.
  int _runs = 0;

  @override
  AsyncValue<T?> build() => const AsyncData<Null>(null);

  /// Runs the action with [input] and returns what it returns: the value of a sync action,
  /// the `Future` of an async one. The state follows it: loading while a `Future` is
  /// pending (a value is never loading, so a sync action costs no frame), then the result or
  /// the error. A failure is rethrown to the caller as well; call through the handle of
  /// `useAction` to have it in the state only.
  ///
  /// Nothing stops a second call while one is pending: both run, each invalidates after its
  /// own success, and the state follows the last one started. Disable the button while
  /// `isPending` if a double write is wrong for the action.
  FutureOr<T> call(I input) {
    final run = ++_runs;
    final int? trace = kFespalierDevTools
        ? traceActionStart(_site, _key, input)
        : null;
    final FutureOr<T> result;
    try {
      result = _run(ref, input);
    } catch (error, stackTrace) {
      _fail(run, error, stackTrace, trace);
      rethrow;
    }
    if (result is! Future<T>) {
      _succeed(run, result, trace);
      return result;
    }
    // Alive until the write is over, whoever watches: the state of a submission that
    // outlives its page is dropped, not written to a disposed provider.
    final link = ref.keepAlive();
    if (run == _runs && ref.mounted) state = const AsyncLoading<Never>();
    return result.then<T>(
      (value) {
        try {
          _succeed(run, value, trace);
        } finally {
          link.close();
        }
        return value;
      },
      onError: (Object error, StackTrace stackTrace) {
        try {
          _fail(run, error, stackTrace, trace);
        } finally {
          link.close();
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }

  /// Back to idle (`AsyncData(null)`), e.g. to clear the error a page shows. A run in
  /// progress still completes and still invalidates, but no longer writes the state.
  void reset() {
    _runs++;
    if (ref.mounted) state = const AsyncData<Null>(null);
  }

  void _succeed(int run, T value, int? trace) {
    if (kFespalierDevTools) traceActionEnd(trace, result: value);
    if (!ref.mounted) return;
    if (run == _runs) state = AsyncData<T?>(value);
    for (final target in _invalidates()) {
      if (target is! ProviderOrFamily) throw _notAProvider(target);
      ref.invalidate(target as ProviderOrFamily);
    }
  }

  void _fail(int run, Object error, StackTrace stackTrace, int? trace) {
    if (kFespalierDevTools) {
      traceActionEnd(trace, failed: true, error: error);
    }
    if (ref.mounted && run == _runs) state = AsyncError<T?>(error, stackTrace);
  }
}

StateError _notAProvider(Object target) => StateError(
  'An action tried to invalidate `$target`, which is not a provider or a '
  'family. Generated code only lists the providers of data.dart files: this '
  'is a bug in fespalier, please report it.',
);

/// The provider of an action with no keys: [run] is the function of `action.dart` and
/// [invalidates] what a success makes stale. Called by the generated file, which passes [site],
/// the action's key in the route tree DevTools reads (since 0.7.0).
ActionProvider<I, T> actionProvider<I, T>(
  FutureOr<T> Function(Ref ref, I input) run, {
  required Iterable<ProviderListenable<AsyncValue<Object?>>> Function()
  invalidates,
  String? site,
}) => NotifierProvider.autoDispose<ActionNotifier<I, T>, AsyncValue<T?>>(
  () => ActionNotifier<I, T>(run, invalidates, site: site),
);

/// The provider family of an action keyed by [K]: its segments and query parameters, like a
/// `data.dart`'s. Called by the generated file, which passes [site] as [actionProvider] does.
NotifierProviderFamily<ActionNotifier<I, T>, AsyncValue<T?>, K>
actionFamily<K, I, T>(
  FutureOr<T> Function(Ref ref, K key, I input) run, {
  required Iterable<ProviderListenable<AsyncValue<Object?>>> Function(K key)
  invalidates,
  String? site,
}) => NotifierProvider.autoDispose
    .family<ActionNotifier<I, T>, AsyncValue<T?>, K>(
      (key) => ActionNotifier<I, T>(
        (ref, input) => run(ref, key, input),
        () => invalidates(key),
        site: site,
        key: key,
      ),
    );

/// What the generated `useAction` hook returns: the action's [state] as of this build, and
/// [call] to run it.
///
/// [R] is what [call] returns, which follows the action: a `Future<T?>` for one that returns
/// a `Future<T>`, a `T?` for a sync one, a `FutureOr<T?>` for one that returns `FutureOr<T>`.
final class ActionHandle<I, T, R> {
  const ActionHandle._(this.state, this.call, this._reset);

  /// Idle (`AsyncData(null)`), loading, the error of the last run, or its result.
  final AsyncValue<T?> state;

  /// Runs the action with the input. It completes with the result, or with `null` when the
  /// action failed: the error is in [state], so `onPressed: () => submit.call(form)` needs
  /// no `try` and cannot leave an unhandled error behind. (`XRoute.submit` throws instead.)
  ///
  /// Call it from an event handler, not from `build`, and not after the widget is gone.
  final R Function(I input) call;

  final void Function() _reset;

  /// Whether a run is in progress: `state.isLoading`.
  bool get isPending => state.isLoading;

  /// Whether the last run failed: `state.hasError`.
  bool get hasError => state.hasError;

  /// Back to idle, e.g. when the page dismisses the error it shows.
  void reset() => _reset();
}

Future<T?> _quietFuture<I, T>(ActionNotifier<I, T> notifier, I input) {
  try {
    return (notifier.call(input) as Future<T>).then<T?>(
      (value) => value,
      onError: (Object _) => null,
    );
  } catch (_) {
    return Future<T?>.value();
  }
}

T? _quietSync<I, T>(ActionNotifier<I, T> notifier, I input) {
  try {
    return notifier.call(input) as T;
  } catch (_) {
    return null;
  }
}

FutureOr<T?> _quietOr<I, T>(ActionNotifier<I, T> notifier, I input) {
  try {
    final result = notifier.call(input);
    if (result is! Future<T>) return result;
    return result.then<T?>((value) => value, onError: (Object _) => null);
  } catch (_) {
    return null;
  }
}

/// What the generated `submit` and `useAction` helpers of an action are built on.
///
/// The three flavours of each follow what the action returns, so that a sync action stays
/// sync: `Action` for `Future<T>`, `ActionSync` for `T` and `ActionOr` for `FutureOr<T>`.
extension ActionRef on WidgetRef {
  /// Runs a `Future<T>` [action] once with [input]: completes with the result, or fails with
  /// what the action threw (the error is in its state as well).
  Future<T> runAction<I, T>(ActionProvider<I, T> action, I input) {
    try {
      return read(action.notifier).call(input) as Future<T>;
    } catch (error, stackTrace) {
      // A non-async function that throws before it returns its Future.
      return Future<T>.error(error, stackTrace);
    }
  }

  /// Runs a sync [action] once with [input]: returns the result at once, or throws what the
  /// action threw.
  T runActionSync<I, T>(ActionProvider<I, T> action, I input) =>
      read(action.notifier).call(input) as T;

  /// Runs a `FutureOr<T>` [action] once with [input]: returns what the action returned, a
  /// value or a `Future`, or throws what the action threw.
  FutureOr<T> runActionOr<I, T>(ActionProvider<I, T> action, I input) =>
      read(action.notifier).call(input);

  /// Watches a `Future<T>` [action]: its state, and `call` to run it. Call it in `build`.
  ActionHandle<I, T, Future<T?>> watchAction<I, T>(
    ActionProvider<I, T> action,
  ) => ActionHandle._(
    watch(action),
    (input) => _quietFuture(read(action.notifier), input),
    () => read(action.notifier).reset(),
  );

  /// Watches a sync [action]: its state, and `call` to run it. Call it in `build`.
  ActionHandle<I, T, T?> watchActionSync<I, T>(ActionProvider<I, T> action) =>
      ActionHandle._(
        watch(action),
        (input) => _quietSync(read(action.notifier), input),
        () => read(action.notifier).reset(),
      );

  /// Watches a `FutureOr<T>` [action]: its state, and `call` to run it. Call it in `build`.
  ActionHandle<I, T, FutureOr<T?>> watchActionOr<I, T>(
    ActionProvider<I, T> action,
  ) => ActionHandle._(
    watch(action),
    (input) => _quietOr(read(action.notifier), input),
    () => read(action.notifier).reset(),
  );
}
