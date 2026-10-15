import 'dart:async';

import 'telemetry.dart';

/// Thrown by a decoder for a message this app is too old to understand (since 0.18.0): a
/// variant, a tag or a field that a newer core added.
///
/// A [ChangeCodec] skips the message (or the batch item) and counts it in
/// [ChangeCodec.unknownCount], apart from the ones that failed to decode. It carries nothing on
/// purpose, so telemetry never sees what the core sent: log the tag yourself before throwing.
final class UnknownChange implements Exception {
  /// The marker: `throw const UnknownChange()`.
  const UnknownChange();

  /// `UnknownChange`.
  @override
  String toString() => 'UnknownChange';
}

/// Decodes a core's raw messages (JSON, bytes, a batch per message) into its events, on the way
/// into a `ChangeFeed` (since 0.18.0).
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
/// 4th, 8th... skip of each kind is a `fespalier.frb.decode` span holding constants and a count,
/// never the message or the error's text. The source stream's own errors pass through unchanged.
sealed class ChangeCodec<R, E> extends StreamTransformerBase<R, E> {
  ChangeCodec._({this.onSkipped});

  /// A codec that turns each raw message into one event with [decode]. Throw [UnknownChange]
  /// from it for a variant this app does not know; anything else it throws is an undecodable
  /// message.
  factory ChangeCodec(
    E Function(R raw) decode, {
    void Function(Object reason, StackTrace stackTrace)? onSkipped,
  }) = _OneCodec<R, E>;

  /// A codec for messages that carry several events: [split] gives a message's items, [decode]
  /// turns one item into an event. An item that throws is skipped alone and the rest of its batch
  /// goes through; a message [split] throws on is skipped whole; no items is no event and no skip.
  static ChangeCodec<S, T> batch<S, I, T>(
    Iterable<I> Function(S raw) split,
    T Function(I item) decode, {
    void Function(Object reason, StackTrace stackTrace)? onSkipped,
  }) => _BatchCodec<S, I, T>(split, decode, onSkipped: onSkipped);

  /// Called once per skipped message or item with what was thrown (an [UnknownChange] or the
  /// decoder's error), inside the stream's delivery: log it and return. What it throws becomes an
  /// error of the decoded stream (an `AsyncError` in the feed's `latest`).
  final void Function(Object reason, StackTrace stackTrace)? onSkipped;

  int _unknownCount = 0;
  int _errorCount = 0;

  /// How many messages or items this codec skipped for an [UnknownChange] since it was made.
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
      reportDecodeSkipped(unknown: unknown, count: count);
    }
    onSkipped?.call(reason, stackTrace);
  }
}

final class _OneCodec<R, E> extends ChangeCodec<R, E> {
  _OneCodec(this._decode, {super.onSkipped}) : super._();

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

final class _BatchCodec<R, I, E> extends ChangeCodec<R, E> {
  _BatchCodec(this._split, this._decode, {super.onSkipped}) : super._();

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
