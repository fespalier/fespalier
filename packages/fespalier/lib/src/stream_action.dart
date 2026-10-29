import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart'
    show NotifierProviderFamily, ProviderListenable, ProviderOrFamily;

import 'devtools/devtools.dart'
    show kFespalierDevTools, traceActionEnd, traceActionStart;
import 'field_errors.dart';
import 'telemetry.dart'
    show
        TelemetrySite,
        telemetryActionEnd,
        telemetryActionStart,
        telemetryWithin;

/// The state of a streaming action (since 0.25.0): a function of an `action.dart` that returns a
/// `Stream<T>`, such as an answer written word by word or the progress of a long write.
///
/// [StreamIdle] until it runs, [StreamRunning] while its stream gives items, then [StreamDone] when
/// the stream ended, [StreamFailed] when it threw, or [StreamCancelled] when the run was stopped
/// (by `cancel()`, `reset()` or a newer run). Each state has the [latest] item and the [count] of
/// items so far, so a page can show what arrived whatever came after.
///
/// A new state is a new object, with no `==` of its own: Riverpod tells the page about every item,
/// even one equal to the item before it.
sealed class StreamActionState<T> {
  const StreamActionState();

  /// The last item the stream gave in this run, or null before the first one (an item may itself
  /// be null: [count] tells the two apart).
  T? get latest;

  /// How many items the stream gave in this run.
  int get count;
}

/// Before the first run, and after `reset()`.
final class StreamIdle<T> extends StreamActionState<T> {
  /// The idle state.
  const StreamIdle();

  @override
  T? get latest => null;

  @override
  int get count => 0;
}

/// A run is listening to its stream: [latest] is the last item so far.
final class StreamRunning<T> extends StreamActionState<T> {
  /// A run with [count] items so far, the last being [latest].
  const StreamRunning({this.latest, this.count = 0});

  @override
  final T? latest;

  @override
  final int count;
}

/// The stream ended: [latest] is its last item.
final class StreamDone<T> extends StreamActionState<T> {
  /// A run whose stream ended after [count] items, the last being [latest].
  const StreamDone({this.latest, this.count = 0});

  @override
  final T? latest;

  @override
  final int count;
}

/// The stream threw [error] (or `validate()` refused the input, or the function threw before it
/// returned its stream). [latest] and [count] say what arrived before.
final class StreamFailed<T> extends StreamActionState<T> {
  /// A run that failed with [error] after [count] items.
  const StreamFailed(
    this.error,
    this.stackTrace, {
    this.latest,
    this.count = 0,
  });

  /// What the stream threw: [FieldErrors] when the input was refused.
  final Object error;

  /// The stack trace of [error].
  final StackTrace stackTrace;

  @override
  final T? latest;

  @override
  final int count;
}

/// The run was stopped before its stream ended: by `cancel()`, by `reset()`, or by a newer run.
/// [latest] is the last item that arrived.
final class StreamCancelled<T> extends StreamActionState<T> {
  /// A run stopped after [count] items, the last being [latest].
  const StreamCancelled({this.latest, this.count = 0});

  @override
  final T? latest;

  @override
  final int count;
}

/// The provider of one function of an `action.dart` that returns a `Stream<T>` (since 0.25.0): what
/// the generated `XRoute.action` (or `XRoute.draftAction`, ...) is, called with the action's keys
/// when it has any. It works without a widget: read `.notifier` from a `ProviderContainer` and call
/// [StreamActionNotifier.call] with `hold: true`.
typedef StreamActionProvider<I, T> =
    NotifierProvider<StreamActionNotifier<I, T>, StreamActionState<T>>;

/// One run of a streaming action: what its end needs.
final class _Run<T> {
  _Run(this.number, this.trace, this.span);

  final int number;
  final int? trace;
  final Object? span;
  final Completer<T?> result = Completer<T?>();

  /// Closes the keep-alive link of a held run.
  void Function()? release;
  StreamSubscription<T>? subscription;
  T? latest;
  int count = 0;
  bool ended = false;
}

/// Runs one function of an `action.dart` that returns a `Stream<T>` (since 0.25.0), and holds its
/// [StreamActionState].
///
/// - `validate()` runs first: an input it refuses never starts the stream.
/// - The last run wins: a call while a run is in progress stops it ([StreamCancelled]) and starts
///   the new one.
/// - A run lives while something watches the provider: when the provider is disposed (the page
///   that watched it went away), the subscription is cancelled, which aborts what the stream was
///   reading. A run started with `hold: true` (what the generated `submit` does) keeps the provider
///   alive until its stream ends, like a `Future` action.
/// - The stream is listened to within the action's telemetry span, so a span made while it runs
///   (an HTTP client's) is its child.
/// - When the stream ends, and when a run is stopped after at least one item, the data the action
///   made stale is invalidated (the route's own `data.dart` and the sections' above it, or what
///   `invalidates` lists), as long as the provider is alive. A failed run invalidates nothing, and
///   neither does a run stopped because the provider was disposed.
/// - [FieldErrors] thrown by the stream end it as [StreamFailed], like any error, and stay
///   readable there. A stream is never retried.
///
/// It starts no timer and no listener of its own: the only subscription is the one on the stream
/// the action returned.
final class StreamActionNotifier<I, T> extends Notifier<StreamActionState<T>> {
  /// Creates the notifier for [_run], invalidating what [_invalidates] lists after the stream
  /// ends. The generated file builds one per key through [streamActionProvider] or
  /// [streamActionFamily]; an app has no reason to.
  ///
  /// [site] and [key] say which action this is to the DevTools extension, and [telemetry] names it
  /// to telemetry, as for `ActionNotifier`; [validate] is the `validate()` beside the action.
  StreamActionNotifier(
    this._run,
    this._invalidates, {
    String? site,
    Object? key,
    TelemetrySite? telemetry,
    FieldErrors? Function(I input)? validate,
  }) : _site = kFespalierDevTools ? site : null,
       _key = kFespalierDevTools ? key : null,
       _telemetry = telemetry,
       _validate = validate;

  final Stream<T> Function(Ref ref, I input) _run;
  final Iterable<ProviderListenable<AsyncValue<Object?>>> Function()
  _invalidates;
  final FieldErrors? Function(I input)? _validate;
  final String? _site;
  final Object? _key;
  final TelemetrySite? _telemetry;

  /// Counts the runs, so that only the last one started writes the state.
  int _runs = 0;

  /// The run in progress, if any.
  _Run<T>? _current;

  /// False once the provider was disposed: nothing reads `ref` after that.
  bool _alive = false;

  @override
  StreamActionState<T> build() {
    _alive = true;
    ref.onDispose(_disposed);
    return StreamIdle<T>();
  }

  /// Runs the action with [input] and listens to its stream. The state follows it: running, with
  /// each item as it comes, then done, failed or cancelled. The `Future` completes with the last
  /// item (null when there was none) when the stream ends or the run is stopped, or fails with what
  /// the stream threw. An input `validate()` refuses, and a function that throws before it returns
  /// its stream, throw here at once, as an `ActionNotifier`'s `call` does.
  ///
  /// With [hold], the provider stays alive until the stream ends, even when nothing watches it
  /// (a submission that outlives its page); without it, the run stops when the provider is
  /// disposed.
  Future<T?> call(I input, {bool hold = false}) {
    final number = ++_runs;
    // The last run wins: the one in progress stops, and no longer writes the state.
    final previous = _current;
    _current = null;
    if (previous != null) _cancelled(previous);
    final int? trace = kFespalierDevTools
        ? traceActionStart(_site, _key, input)
        : null;
    final telemetry = _telemetry;
    final Object? span = telemetry == null
        ? null
        : telemetryActionStart(telemetry);
    final run = _Run<T>(number, trace, span);
    if (_validate?.call(input) case final errors? when !errors.isEmpty) {
      _failed(run, errors, StackTrace.current, isAsync: false);
      throw errors;
    }
    if (hold) run.release = ref.keepAlive().close;
    _current = run;
    if (_alive && ref.mounted) state = StreamRunning<T>();
    try {
      // Within the action's span: the stream's body runs when it is listened to, so a span it
      // makes (an HTTP client's) is the action's child.
      final subscription = span == null
          ? _listen(run, input)
          : telemetryWithin(span, () => _listen(run, input));
      if (run.ended) {
        subscription.cancel().ignore();
      } else {
        run.subscription = subscription;
      }
    } catch (error, stackTrace) {
      _failed(run, error, stackTrace, isAsync: false);
      rethrow;
    }
    return run.result.future;
  }

  StreamSubscription<T> _listen(_Run<T> run, I input) =>
      _run(ref, input).listen(
        (item) {
          if (run.ended) return;
          run
            ..latest = item
            ..count += 1;
          if (_writes(run)) {
            state = StreamRunning<T>(latest: item, count: run.count);
          }
        },
        onError: (Object error, StackTrace stackTrace) =>
            _failed(run, error, stackTrace, isAsync: true),
        onDone: () => _done(run),
        cancelOnError: true,
      );

  /// Stops the run in progress: it ends as [StreamCancelled], and, after at least one item, what
  /// the action made stale is invalidated. Nothing happens when no run is in progress.
  void cancel() {
    final run = _current;
    if (run == null) return;
    _cancelled(run);
  }

  /// Stops the run in progress (as [cancel] does) and goes back to [StreamIdle], e.g. to clear the
  /// error or the text a page shows.
  void reset() {
    final run = _current;
    _runs++;
    if (run != null) _cancelled(run);
    if (_alive && ref.mounted) state = StreamIdle<T>();
  }

  /// Whether [run] may write the state: it is the last one started and the provider is alive.
  bool _writes(_Run<T> run) => run.number == _runs && _alive && ref.mounted;

  /// Marks [run] ended, once; false when it already was.
  bool _settle(_Run<T> run) {
    if (run.ended) return false;
    run.ended = true;
    if (identical(_current, run)) _current = null;
    return true;
  }

  void _done(_Run<T> run) {
    if (!_settle(run)) return;
    if (kFespalierDevTools) traceActionEnd(run.trace, result: run.latest);
    if (_telemetry != null) {
      telemetryActionEnd(run.span, isAsync: true, items: run.count);
    }
    try {
      if (_alive && ref.mounted) {
        if (run.number == _runs) {
          state = StreamDone<T>(latest: run.latest, count: run.count);
        }
        _invalidate();
      }
    } finally {
      run.release?.call();
      run.result.complete(run.latest);
    }
  }

  void _failed(
    _Run<T> run,
    Object error,
    StackTrace stackTrace, {
    required bool isAsync,
  }) {
    if (!_settle(run)) return;
    if (kFespalierDevTools) {
      traceActionEnd(run.trace, failed: true, error: error);
    }
    if (_telemetry != null) {
      telemetryActionEnd(
        run.span,
        isAsync: isAsync,
        failed: true,
        error: error,
        stackTrace: stackTrace,
        invalid: error is FieldErrors,
        items: run.count,
      );
    }
    if (_writes(run)) {
      state = StreamFailed<T>(
        error,
        stackTrace,
        latest: run.latest,
        count: run.count,
      );
    }
    run.release?.call();
    // A refusal before the stream started is thrown by `call` itself, not through its Future.
    if (isAsync) run.result.completeError(error, stackTrace);
  }

  /// Stops [run]: its subscription is cancelled (which aborts what the stream was reading), and it
  /// ends as cancelled. While the provider is alive, the state says so and, after an item, what
  /// the action made stale is invalidated.
  void _cancelled(_Run<T> run) {
    if (!_settle(run)) return;
    // What the stream's own clean-up throws has nobody to tell: the run is over.
    run.subscription?.cancel().ignore();
    if (kFespalierDevTools) traceActionEnd(run.trace, result: run.latest);
    if (_telemetry != null) {
      telemetryActionEnd(
        run.span,
        isAsync: true,
        cancelled: true,
        items: run.count,
      );
    }
    try {
      if (_alive && ref.mounted) {
        if (run.number == _runs) {
          state = StreamCancelled<T>(latest: run.latest, count: run.count);
        }
        if (run.count > 0) _invalidate();
      }
    } finally {
      run.release?.call();
      run.result.complete(run.latest);
    }
  }

  /// The provider is disposed (nothing watches it and no run holds it, or it is rebuilt): the run
  /// in progress stops. Nothing is written or invalidated: `ref` is not usable here.
  void _disposed() {
    _alive = false;
    final run = _current;
    if (run != null) _cancelled(run);
  }

  void _invalidate() {
    for (final target in _invalidates()) {
      if (target is! ProviderOrFamily) throw _notAProvider(target);
      ref.invalidate(target as ProviderOrFamily);
    }
  }
}

StateError _notAProvider(Object target) => StateError(
  'A streaming action tried to invalidate `$target`, which is not a provider '
  'or a family. Generated code only lists the providers of data.dart files: '
  'this is a bug in fespalier, please report it.',
);

/// The provider of a streaming action with no keys (since 0.25.0): [run] is the function of
/// `action.dart` and [invalidates] what it makes stale. Called by the generated file, which passes
/// [site] and, in an app made with `telemetry: true`, [telemetry], as for `actionProvider`.
StreamActionProvider<I, T> streamActionProvider<I, T>(
  Stream<T> Function(Ref ref, I input) run, {
  required Iterable<ProviderListenable<AsyncValue<Object?>>> Function()
  invalidates,
  String? site,
  TelemetrySite? telemetry,
  FieldErrors? Function(I input)? validate,
}) =>
    NotifierProvider.autoDispose<
      StreamActionNotifier<I, T>,
      StreamActionState<T>
    >(
      () => StreamActionNotifier<I, T>(
        run,
        invalidates,
        site: site,
        telemetry: telemetry,
        validate: validate,
      ),
    );

/// The provider family of a streaming action keyed by [K] (since 0.25.0): its segments and query
/// parameters, like a `data.dart`'s. Called by the generated file, as [streamActionProvider] is.
NotifierProviderFamily<StreamActionNotifier<I, T>, StreamActionState<T>, K>
streamActionFamily<K, I, T>(
  Stream<T> Function(Ref ref, K key, I input) run, {
  required Iterable<ProviderListenable<AsyncValue<Object?>>> Function(K key)
  invalidates,
  String? site,
  TelemetrySite? telemetry,
  FieldErrors? Function(I input)? validate,
}) => NotifierProvider.autoDispose
    .family<StreamActionNotifier<I, T>, StreamActionState<T>, K>(
      (key) => StreamActionNotifier<I, T>(
        (ref, input) => run(ref, key, input),
        () => invalidates(key),
        site: site,
        key: key,
        telemetry: telemetry,
        validate: validate,
      ),
    );

/// What the generated `useAction` hook of a streaming action returns (since 0.25.0): its [state]
/// as of this build, [call] to run it, and [cancel] to stop it.
final class StreamActionHandle<I, T> {
  const StreamActionHandle._(this.state, this.call, this._cancel, this._reset);

  /// Idle, running with the latest item, done, failed or cancelled.
  final StreamActionState<T> state;

  /// Runs the action with the input. The run lives while the page watches the action: it stops
  /// when the page goes away. It completes with the last item, or with `null` when the action
  /// failed: the error is in [state], so `onPressed: () => draft.call(topic)` needs no `try`.
  /// (`XRoute.submit` throws instead, and keeps the run alive until its stream ends.)
  ///
  /// Call it from an event handler, not from `build`, and not after the widget is gone.
  final Future<T?> Function(I input) call;

  final void Function() _cancel;
  final void Function() _reset;

  /// Whether a run is in progress.
  bool get isPending => state is StreamRunning<T>;

  /// Whether the last run failed.
  bool get hasError => state is StreamFailed<T>;

  /// What the last run said of the input's fields, when it failed with [FieldErrors] (thrown by the
  /// stream or refused by its `validate()`); null otherwise.
  FieldErrors? get fieldErrors => switch (state) {
    StreamFailed<T>(error: final FieldErrors e) => e,
    _ => null,
  };

  /// The latest item of the last run, whatever its state; null before the first one.
  T? get value => state.latest;

  /// Stops the run in progress; it ends as cancelled.
  void cancel() => _cancel();

  /// Stops the run in progress and goes back to idle.
  void reset() => _reset();
}

Future<T?> _quietStream<I, T>(StreamActionNotifier<I, T> notifier, I input) {
  try {
    return notifier
        .call(input)
        .then<T?>((value) => value, onError: (Object _) => null);
  } catch (_) {
    return Future<T?>.value();
  }
}

/// What the generated `submit` and `useAction` helpers of a streaming action are built on (since
/// 0.25.0).
extension StreamActionRef on WidgetRef {
  /// Runs a streaming [action] once with [input], holding it alive until its stream ends, even
  /// when the page goes away: completes with the last item, or fails with what the stream threw
  /// (the error is in its state as well).
  Future<T?> runActionStream<I, T>(StreamActionProvider<I, T> action, I input) {
    try {
      return read(action.notifier).call(input, hold: true);
    } catch (error, stackTrace) {
      // A refused input, or a function that throws before it returns its stream.
      return Future<T?>.error(error, stackTrace);
    }
  }

  /// Watches a streaming [action]: its state, `call` to run it and `cancel` to stop it. Call it in
  /// `build`.
  StreamActionHandle<I, T> watchActionStream<I, T>(
    StreamActionProvider<I, T> action,
  ) => StreamActionHandle._(
    watch(action),
    (input) => _quietStream(read(action.notifier), input),
    () => read(action.notifier).cancel(),
    () => read(action.notifier).reset(),
  );
}
