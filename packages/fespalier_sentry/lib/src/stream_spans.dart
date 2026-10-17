import 'package:sentry_flutter/sentry_flutter.dart';

import 'keys.dart';
import 'spans.dart';

/// The spans of `traceLifecycle: stream` (since 0.19.0), made with `startInactiveSpan`.
///
/// A segment and its children are never idle spans (an idle span starts a timer) and never bound
/// to a scope: the parent of each is given, so two screens that overlap stay apart. The sink ends
/// every span itself.
final class StreamSpans implements Spans {
  /// Spans on [hub].
  StreamSpans(this._hub);

  final Hub _hub;

  /// The newest segment this sink started: what an operation that no span is active for belongs
  /// to, as a transaction bound to the scope is in `traceLifecycle: static`.
  _StreamSpan? _latest;

  /// The time on the SDK's own clock, which a span without an end time reads too.
  DateTime _now() =>
      // `Hub.options` is `@internal`, and so is the active span below: see `readHub`.
      // ignore: invalid_use_of_internal_member
      _hub.options.clock();

  @override
  SpanHandle? active() {
    // ignore: invalid_use_of_internal_member
    final zone = _hub.getActiveSpan();
    if (zone != null) return _StreamSpan(this, zone);
    final latest = _latest;
    return latest == null || latest.finished ? null : latest;
  }

  @override
  bool unbound(Scope scope) =>
      // ignore: invalid_use_of_internal_member
      _hub.getActiveSpan() == null;

  @override
  ScreenSpan startScreen() {
    final span = _hub.startInactiveSpan(
      'navigate',
      parentSpan: null,
      attributes: {
        SentryKeys.spanOp: SentryAttribute.string(SentryKeys.uiLoad),
        SentryKeys.spanOrigin: SentryAttribute.string(
          SentryKeys.navigationOrigin,
        ),
        SentryKeys.segmentNameSource: SentryAttribute.string('route'),
      },
    );
    final screen = _StreamScreen(this, span);
    _latest = screen;
    return screen;
  }

  @override
  SpanHandle startAction(String name) {
    final span = _hub.startInactiveSpan(
      name,
      parentSpan: null,
      attributes: {
        SentryKeys.spanOp: SentryAttribute.string(SentryKeys.actionOp),
        SentryKeys.spanOrigin: SentryAttribute.string(
          SentryKeys.navigationOrigin,
        ),
        SentryKeys.segmentNameSource: SentryAttribute.string('component'),
      },
    );
    return _latest = _StreamSpan(this, span);
  }
}

/// The attribute for [value]: the sink writes strings, booleans and numbers, never anything else.
SentryAttribute _attribute(Object value) => switch (value) {
  final bool b => SentryAttribute.bool(b),
  final int i => SentryAttribute.int(i),
  final double d => SentryAttribute.double(d),
  _ => SentryAttribute.string('$value'),
};

class _StreamSpan implements SpanHandle {
  _StreamSpan(this._spans, this._span, [this._screen]);

  final StreamSpans _spans;
  final SentrySpanV2 _span;

  /// The segment of a screen this span is a child of, when it is one.
  final _StreamScreen? _screen;

  bool _finished = false;

  /// The screen that holds the end of this span until it has its name.
  _StreamScreen? get _holder => _screen;

  @override
  bool get finished => _finished;

  @override
  void set(String key, Object value) =>
      _span.setAttribute(key, _attribute(value));

  /// A streamed span has no tags: an attribute carries it.
  @override
  void tag(String key, String value) => set(key, value);

  @override
  SpanHandle child(String op, String description) {
    final span = _spans._hub.startInactiveSpan(
      description,
      parentSpan: _span,
      attributes: {
        SentryKeys.spanOp: SentryAttribute.string(op),
        SentryKeys.spanOrigin: SentryAttribute.string(
          SentryKeys.navigationOrigin,
        ),
      },
    );
    return _StreamSpan(_spans, span, _holder);
  }

  @override
  void finish(SpanStatus status, {bool failed = false}) {
    if (_finished) return;
    _finished = true;
    final end = _spans._now();
    final screen = _holder;
    if (screen != null && !screen.isNamed) {
      // Sentry copies the segment's name onto a span when the span ends: wait for the route.
      screen._held.add(() => _end(failed, end));
    } else {
      _end(failed, end);
    }
  }

  void _end(bool failed, DateTime end) {
    _span.status = failed ? SentrySpanStatusV2.error : SentrySpanStatusV2.ok;
    _span.end(endTimestamp: end);
  }

  /// Streaming spans are linked to an event through the trace context, not through the scope's
  /// span (`Scope.span` is the static API's): the event takes `contexts.trace` from the scope.
  @override
  bool boundTo(Scope scope) => false;

  @override
  void attachTo(Scope scope) {
    final span = _span;
    if (span is! RecordingSentrySpanV2) return;
    final op = span.attributes[SentryKeys.spanOp]?.value;
    fire(
      scope.setContexts(
        SentryTraceContext.type,
        SentryTraceContext(
          traceId: span.traceId,
          spanId: span.spanId,
          parentSpanId: span.parentSpan?.spanId,
          sampled: span.samplingDecision.sampled,
          operation: op is String ? op : 'default',
        ),
      ),
    );
  }
}

final class _StreamScreen extends _StreamSpan implements ScreenSpan {
  _StreamScreen(super.spans, super.span);

  /// The ends of the children that ended before the route was known.
  final List<void Function()> _held = [];

  bool isNamed = false;

  @override
  _StreamScreen get _holder => this;

  @override
  void named(String name) {
    _span.name = name;
    _release();
  }

  @override
  void finish(SpanStatus status, {bool failed = false}) {
    // Superseded, or ended before it was named: the children end first, as in every other case.
    _release();
    super.finish(status, failed: failed);
  }

  void _release() {
    isNamed = true;
    final held = List<void Function()>.of(_held);
    _held.clear();
    for (final end in held) {
      end();
    }
  }

  @override
  void initialDisplay(String name) {
    final end = _spans._now();
    final ttid = _display(
      '$name initial display',
      SentryKeys.initialDisplayOp,
      end,
    );
    ttid.setAttribute(SentryKeys.ttidValue, _milliseconds(end));
    ttid.end(endTimestamp: end);
  }

  @override
  void fullDisplay(String name, {required bool deadline}) {
    final end = _spans._now();
    final ttfd = _display('$name full display', SentryKeys.fullDisplayOp, end);
    if (deadline) {
      // Streamed spans have no deadline status: it is an error, with no value.
      ttfd.status = SentrySpanStatusV2.error;
    } else {
      ttfd.setAttribute(SentryKeys.ttfdValue, _milliseconds(end));
    }
    ttfd.end(endTimestamp: end);
  }

  SentrySpanV2 _display(String name, String op, DateTime end) =>
      _spans._hub.startInactiveSpan(
        name,
        parentSpan: _span,
        startTimestamp: _span.startTimestamp,
        attributes: {
          SentryKeys.spanOp: SentryAttribute.string(op),
          SentryKeys.spanOrigin: SentryAttribute.string(
            SentryKeys.navigationOrigin,
          ),
        },
      );

  /// The time from the start of the screen to [end], as Sentry's own display spans write it.
  SentryAttribute _milliseconds(DateTime end) => SentryAttribute.double(
    end.difference(_span.startTimestamp).inMilliseconds.toDouble(),
  );
}
