import 'package:sentry_flutter/sentry_flutter.dart';

import 'keys.dart';
import 'spans.dart';

/// The spans of `traceLifecycle: static`, made with `startTransaction` and `startChild`.
final class StaticSpans implements Spans {
  /// Spans on [hub].
  StaticSpans(this._hub);

  final Hub _hub;

  @override
  SpanHandle? active() {
    final span = _hub.getSpan();
    return span == null ? null : _StaticSpan(span);
  }

  @override
  bool unbound(Scope scope) => scope.span == null;

  @override
  ScreenSpan startScreen() {
    // No `waitForChildren` and no `autoFinishAfter`: Sentry starts no timer for this. It ends when
    // the screen's data has arrived, or when the next navigation starts.
    final tx = _hub.startTransactionWithContext(
      SentryTransactionContext(
        'navigate',
        SentryKeys.uiLoad,
        transactionNameSource: SentryTransactionNameSource.route,
        origin: SentryKeys.navigationOrigin,
      ),
      bindToScope: true,
    );
    return _StaticScreen(tx);
  }

  @override
  SpanHandle startAction(String name) {
    final tx = _hub.startTransactionWithContext(
      SentryTransactionContext(
        name,
        SentryKeys.actionOp,
        transactionNameSource: SentryTransactionNameSource.component,
        origin: SentryKeys.navigationOrigin,
      ),
      bindToScope: true,
    );
    return _StaticSpan(tx);
  }
}

class _StaticSpan implements SpanHandle {
  _StaticSpan(this._span);

  final ISentrySpan _span;

  @override
  bool get finished => _span.finished;

  @override
  void set(String key, Object value) => _span.setData(key, value);

  @override
  void tag(String key, String value) => _span.setTag(key, value);

  @override
  SpanHandle child(String op, String description) =>
      _StaticSpan(_span.startChild(op, description: description));

  @override
  void finish(SpanStatus status, {bool failed = false}) =>
      fire(_span.finish(status: status));

  @override
  bool boundTo(Scope scope) => identical(scope.span, _span);

  @override
  void attachTo(Scope scope) => scope.span = _span;
}

final class _StaticScreen extends _StaticSpan implements ScreenSpan {
  _StaticScreen(super.span);

  @override
  void named(String name) {}

  @override
  void initialDisplay(String name) {
    final ttid = _span.startChild(
      SentryKeys.initialDisplayOp,
      description: '$name initial display',
      startTimestamp: _span.startTimestamp,
    );
    fire(ttid.finish(status: const SpanStatus.ok()));
    _measure(SentryKeys.ttidMeasurement, ttid.endTimestamp);
  }

  @override
  void fullDisplay(String name, {required bool deadline}) {
    final span = _span.startChild(
      SentryKeys.fullDisplayOp,
      description: '$name full display',
      startTimestamp: _span.startTimestamp,
    );
    fire(
      span.finish(
        status: deadline
            ? const SpanStatus.deadlineExceeded()
            : const SpanStatus.ok(),
      ),
    );
    if (!deadline) _measure(SentryKeys.ttfdMeasurement, span.endTimestamp);
  }

  /// Sets the measurement [name] of the transaction: the time from its start to [end].
  void _measure(String name, DateTime? end) {
    if (end == null) return;
    _span.setMeasurement(
      name,
      end.difference(_span.startTimestamp).inMilliseconds,
      unit: DurationSentryMeasurementUnit.milliSecond,
    );
  }
}
