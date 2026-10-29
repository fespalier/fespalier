import 'dart:async';

import 'package:fespalier/fespalier.dart';

import 'telemetry.dart';

/// Thrown by a decoder for a message this app is too old to understand (since 0.18.0, in
/// fespalier_stream since 0.25.0): a variant, a tag or a field that a newer server or core added.
///
/// An [EventCodec] skips the message (or the batch item) and counts it in
/// [EventCodec.unknownCount], apart from the ones that failed to decode. It carries nothing on
/// purpose, so telemetry never sees what was sent: log the tag yourself before throwing.
final class UnknownChange implements Exception {
  /// The marker: `throw const UnknownChange()`.
  const UnknownChange();

  /// `UnknownChange`.
  @override
  String toString() => 'UnknownChange';
}

/// The names an [EventCodec] reports a skip under (since 0.25.0).
///
/// [stream] is the default: `fespalier.stream.decode`, with `fespalier.stream.result` and
/// `fespalier.stream.skipped`. A package that reported a codec of its own under its own names
/// before keeps them with a report of its own: fespalier_frb's `ChangeCodec` reports
/// `fespalier.frb.decode` (a package's names are its contract, so they are not renamed). Each name
/// is a constant; nothing from the wire goes into one.
final class DecodeReport {
  /// A report under [operation], whose end carries [resultAttribute] (`unknown` or `error`) and
  /// [skippedAttribute] (the count).
  ///
  /// This constructor exists for companion packages that keep names of their own (fespalier_frb's
  /// `ChangeCodec` reports `fespalier.frb.decode`); an app uses [DecodeReport.stream], the
  /// default. It is not marked `@internal`, because another package could not then use it
  /// without an analyzer warning.
  const DecodeReport({
    required this.operation,
    required this.resultAttribute,
    required this.skippedAttribute,
  });

  /// `fespalier.stream.decode` (see [FespalierStreamConventions.decode]).
  static const DecodeReport stream = DecodeReport(
    operation: FespalierStreamConventions.decode,
    resultAttribute: FespalierStreamConventions.result,
    skippedAttribute: FespalierStreamConventions.skipped,
  );

  /// The span's name (`TelemetryOp.custom`).
  final String operation;

  /// The end attribute that says why: `unknown` for an [UnknownChange], `error` for anything else.
  final String resultAttribute;

  /// The end attribute that counts the skips of that kind so far, this one included (an `int`).
  final String skippedAttribute;

  /// Reports one skip as a span that starts and ends at once: ends `skipped` with result
  /// `unknown`, or `error` with result `error`, and the count. Never the message, a name from the
  /// wire or the error. Without a sink, one null check.
  ///
  /// The span is a **root span**: the pair runs in the root zone, because a message is decoded in
  /// the zone of whoever first watched the feed (a page's, long gone), and a sink that reads
  /// `Zone.current` (dartastic's `Context.current`) would make the span a child of whatever that
  /// zone was running. It is synchronous: no `Future`, no microtask, no timer.
  void _skipped({required bool unknown, required int count}) {
    if (FespalierTelemetry.current == null) return;
    Zone.root.run(() {
      final token = FespalierTelemetry.begin(
        TelemetryStart(TelemetryOp.custom, name: operation),
      );
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          unknown ? TelemetryOutcome.skipped : TelemetryOutcome.error,
          attributes: <String, Object>{
            resultAttribute: unknown ? 'unknown' : 'error',
            skippedAttribute: count,
          },
        ),
      );
    });
  }
}

/// Decodes raw messages (JSON, bytes, a server event's data, a batch per message) into events, on
/// the way into a `ChangeFeed` or out of a `LiveConnection` (since 0.25.0; fespalier_frb's
/// `ChangeCodec` since 0.18.0, which is now this under its own telemetry names).
///
/// It is a `StreamTransformer`: use it in a feed's `open`, or on a connection
/// (`connection.transform(codec)`), and the feed numbers what it decodes.
///
/// ```dart
/// final orderCodec = EventCodec<ServerEvent, OrderEvent>((e) => OrderEvent.fromJson(e.data));
/// final changes = ChangeFeed<OrderEvent>.live(
///   (ref, lastEventId) => ServerEvents(ref.watch(apiTransport), ordersUrl, lastEventId: lastEventId)
///       .transform(orderCodec),
/// );
/// ```
///
/// What a decoder throws never ends the stream: the message (or batch item) is skipped, gets no
/// `Change.seq`, moves no topic, is counted ([unknownCount] for an [UnknownChange], [errorCount]
/// for anything else) and passed to [onSkipped]. With a telemetry sink installed, the 1st, 2nd,
/// 4th, 8th... skip of each kind is a `fespalier.stream.decode` span (a root span, not under
/// whatever was running; [DecodeReport]) holding constants and a count, never the message or the
/// error's text. The source stream's own errors pass through unchanged.
sealed class EventCodec<R, E> extends StreamTransformerBase<R, E> {
  EventCodec._({this.onSkipped, required DecodeReport report})
    : _report = report;

  /// A codec that turns each raw message into one event with [decode]. Throw [UnknownChange]
  /// from it for a variant this app does not know; anything else it throws is an undecodable
  /// message. [report] names the span of a skip ([DecodeReport.stream] by default).
  factory EventCodec(
    E Function(R raw) decode, {
    void Function(Object reason, StackTrace stackTrace)? onSkipped,
    DecodeReport report,
  }) = _OneCodec<R, E>;

  /// A codec for messages that carry several events: [split] gives a message's items, [decode]
  /// turns one item into an event. An item that throws is skipped alone and the rest of its batch
  /// goes through; a message [split] throws on is skipped whole; no items is no event and no skip.
  static EventCodec<S, T> batch<S, I, T>(
    Iterable<I> Function(S raw) split,
    T Function(I item) decode, {
    void Function(Object reason, StackTrace stackTrace)? onSkipped,
    DecodeReport report = DecodeReport.stream,
  }) =>
      _BatchCodec<S, I, T>(split, decode, onSkipped: onSkipped, report: report);

  /// Called once per skipped message or item with what was thrown (an [UnknownChange] or the
  /// decoder's error), inside the stream's delivery: log it and return. What it throws becomes an
  /// error of the decoded stream (an `AsyncError` in the feed's `latest`), and the rest of that
  /// message's events are dropped with it: the items of a batch decoded before it, and those
  /// after it.
  final void Function(Object reason, StackTrace stackTrace)? onSkipped;

  final DecodeReport _report;

  int _unknownCount = 0;
  int _errorCount = 0;

  /// How many messages or items this codec skipped for an [UnknownChange] since it was made.
  /// Each subscription decodes on its own, so a bad message that two listeners of a broadcast
  /// source both receive is counted twice.
  int get unknownCount => _unknownCount;

  /// How many messages or items this codec skipped because their decoding threw anything else.
  int get errorCount => _errorCount;

  /// The events [raw] carries, in order: one, several (a batch) or none (skipped, or an empty
  /// batch). Never throws, except what [onSkipped] throws.
  List<E> decode(R raw);

  /// [stream] with each message replaced by the events [decode] gives. Errors, the end and a
  /// cancel pass through.
  @override
  Stream<E> bind(Stream<R> stream) => stream.expand(decode);

  void _skip(Object reason, StackTrace stackTrace) {
    final unknown = reason is UnknownChange;
    final count = unknown ? ++_unknownCount : ++_errorCount;
    // The 1st, 2nd, 4th, 8th... of each kind: a handful of spans, never one per message.
    if ((count & (count - 1)) == 0) {
      _report._skipped(unknown: unknown, count: count);
    }
    onSkipped?.call(reason, stackTrace);
  }
}

final class _OneCodec<R, E> extends EventCodec<R, E> {
  _OneCodec(this._decode, {super.onSkipped, super.report = DecodeReport.stream})
    : super._();

  final E Function(R raw) _decode;

  @override
  List<E> decode(R raw) {
    try {
      return [_decode(raw)];
    } catch (reason, stackTrace) {
      _skip(reason, stackTrace);
      return <E>[];
    }
  }
}

final class _BatchCodec<R, I, E> extends EventCodec<R, E> {
  _BatchCodec(
    this._split,
    this._decode, {
    super.onSkipped,
    required super.report,
  }) : super._();

  final Iterable<I> Function(R raw) _split;
  final E Function(I item) _decode;

  /// The items of [raw], read at once, or null when reading them threw (reported).
  List<I>? _items(R raw) {
    try {
      return _split(raw).toList(growable: false);
    } catch (reason, stackTrace) {
      _skip(reason, stackTrace);
      return null;
    }
  }

  @override
  List<E> decode(R raw) {
    final items = _items(raw);
    if (items == null) return <E>[];
    final events = <E>[];
    for (final item in items) {
      try {
        events.add(_decode(item));
      } catch (reason, stackTrace) {
        _skip(reason, stackTrace);
      }
    }
    return events;
  }
}
