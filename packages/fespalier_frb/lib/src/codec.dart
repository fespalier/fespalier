import 'dart:async';

import 'package:fespalier_stream/fespalier_stream.dart';

import 'telemetry.dart';

/// The names a [ChangeCodec] reports a skip under: fespalier_frb's own, unchanged since 0.18.0.
const DecodeReport _frbReport = DecodeReport(
  operation: frbDecodeOp,
  resultAttribute: frbResultAttribute,
  skippedAttribute: frbSkippedAttribute,
);

/// Decodes a core's raw messages (JSON, bytes, a batch per message) into its events, on the way
/// into a `ChangeFeed` (since 0.18.0).
///
/// Since 0.25.0 it is a facade over fespalier_stream's `EventCodec`, with the same members and
/// behaviour, that reports under fespalier_frb's names: `fespalier.frb.decode`, never
/// `fespalier.stream.decode`. A codec for a server's events is an `EventCodec`.
///
/// It is a `StreamTransformer`: use it in the feed's `open`, and the feed numbers what it decodes.
///
/// ```dart
/// final coreCodec = ChangeCodec<String, CoreEvent>(decodeCoreEvent);
/// final changes = ChangeFeed<CoreEvent>(
///   (ref) => ref.watch(coreProvider).rawChanges().transform(coreCodec),
/// );
/// ```
///
/// What a decoder throws never ends the stream: the message (or batch item) is skipped, gets no
/// `Change.seq`, moves no topic, is counted ([unknownCount] for an [UnknownChange], [errorCount]
/// for anything else) and passed to [onSkipped]. With a telemetry sink installed, the 1st, 2nd,
/// 4th, 8th... skip of each kind is a `fespalier.frb.decode` span (a root span, not under whatever
/// was running) holding constants and a count, never the message or the error's text. The source
/// stream's own errors pass through unchanged.
final class ChangeCodec<R, E> extends StreamTransformerBase<R, E> {
  ChangeCodec._(this._codec);

  /// A codec that turns each raw message into one event with [decode]. Throw [UnknownChange]
  /// from it for a variant this app does not know; anything else it throws is an undecodable
  /// message.
  factory ChangeCodec(
    E Function(R raw) decode, {
    void Function(Object reason, StackTrace stackTrace)? onSkipped,
  }) => ChangeCodec<R, E>._(
    EventCodec<R, E>(decode, onSkipped: onSkipped, report: _frbReport),
  );

  /// A codec for messages that carry several events: [split] gives a message's items, [decode]
  /// turns one item into an event. An item that throws is skipped alone and the rest of its batch
  /// goes through; a message [split] throws on is skipped whole; no items is no event and no skip.
  static ChangeCodec<S, T> batch<S, I, T>(
    Iterable<I> Function(S raw) split,
    T Function(I item) decode, {
    void Function(Object reason, StackTrace stackTrace)? onSkipped,
  }) => ChangeCodec<S, T>._(
    EventCodec.batch<S, I, T>(
      split,
      decode,
      onSkipped: onSkipped,
      report: _frbReport,
    ),
  );

  final EventCodec<R, E> _codec;

  /// Called once per skipped message or item with what was thrown (an [UnknownChange] or the
  /// decoder's error), inside the stream's delivery: log it and return. What it throws becomes an
  /// error of the decoded stream (an `AsyncError` in the feed's `latest`), and the rest of that
  /// message's events are dropped with it: the items of a batch decoded before it, and those
  /// after it.
  void Function(Object reason, StackTrace stackTrace)? get onSkipped =>
      _codec.onSkipped;

  /// How many messages or items this codec skipped for an [UnknownChange] since it was made.
  /// Each subscription decodes on its own, so a bad message that two listeners of a broadcast
  /// source both receive is counted twice.
  int get unknownCount => _codec.unknownCount;

  /// How many messages or items this codec skipped because their decoding threw anything else.
  int get errorCount => _codec.errorCount;

  /// The events [raw] carries, in order: one, several (a batch) or none (skipped, or an empty
  /// batch). Never throws, except what [onSkipped] throws.
  List<E> decode(R raw) => _codec.decode(raw);

  /// [stream] with each message replaced by the events [decode] gives. Errors, the end and a
  /// cancel pass through.
  @override
  Stream<E> bind(Stream<R> stream) => _codec.bind(stream);
}
