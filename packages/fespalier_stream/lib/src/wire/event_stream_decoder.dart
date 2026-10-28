import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'server_event.dart';

/// An event of the stream was larger than the decoder allows (since 0.25.0): the server sent more
/// than [limit] bytes without the blank line that ends an event. The decoder stops there, so a
/// server that never ends an event cannot fill the device's memory.
final class EventStreamTooLarge implements Exception {
  /// The limit that was passed.
  const EventStreamTooLarge(this.limit);

  /// The `maxEventBytes` of the decoder.
  final int limit;

  @override
  String toString() => 'EventStreamTooLarge: an event exceeded $limit bytes';
}

/// Decodes the bytes of a `text/event-stream` body into [EventStreamItem]s (since 0.25.0), by the
/// WHATWG HTML standard's "event stream interpretation".
///
/// - The body is UTF-8 (a malformed sequence becomes U+FFFD) and a byte order mark at its start
///   is skipped. A line ends with CR LF, LF or CR, and a line or a code point split across two
///   chunks is put back together.
/// - `data:` lines are joined with a line feed; a blank line dispatches a [ServerEvent] when the
///   block had at least one `data:` line. The space after the colon is optional and removed once.
/// - `event:` names the type (`message` when absent). `id:` sets the last event ID (one with a NUL
///   in it is ignored, an empty one clears it), which every later event carries.
/// - `retry:` with ASCII digits only is a [RetryHint]; a comment line (`:`) is a [Heartbeat]; any
///   other field is ignored.
/// - The end of the body drops an event that has no blank line after it.
///
/// [maxEventBytes] bounds the bytes between two blank lines (comments included): past it the
/// output fails with [EventStreamTooLarge] and ends, and the rest of the body is not read.
///
/// It is a plain transformer: pausing or cancelling its output pauses or cancels the body, and it
/// keeps no timer.
final class EventStreamDecoder
    extends StreamTransformerBase<List<int>, EventStreamItem> {
  /// A decoder that refuses an event of more than [maxEventBytes] bytes (1 MiB by default).
  const EventStreamDecoder({this.maxEventBytes = 1 << 20})
    : assert(maxEventBytes > 0, 'maxEventBytes must be positive');

  /// The most bytes an event may take, from the end of the previous one to its blank line.
  final int maxEventBytes;

  @override
  Stream<EventStreamItem> bind(Stream<List<int>> stream) =>
      Stream<EventStreamItem>.eventTransformed(
        stream,
        (sink) => _DecoderSink(sink, maxEventBytes),
      );
}

const int _cr = 0x0D;
const int _lf = 0x0A;
const Utf8Decoder _utf8 = Utf8Decoder(allowMalformed: true);

/// The parser: bytes in, items out. Lines are cut at the byte level (CR and LF never occur inside
/// a multi-byte UTF-8 sequence), then each whole line is decoded, so nothing is split.
final class _DecoderSink implements EventSink<List<int>> {
  _DecoderSink(this._out, this._limit);

  final EventSink<EventStreamItem> _out;
  final int _limit;

  final BytesBuilder _line = BytesBuilder();
  bool _afterCr = false;
  bool _first = true;
  bool _stopped = false;

  /// Bytes since the end of the previous event, counted against [_limit].
  int _eventBytes = 0;

  final StringBuffer _data = StringBuffer();
  bool _hasData = false;
  String _type = '';
  String _lastId = '';

  @override
  void add(List<int> chunk) {
    if (_stopped) return;
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      final byte = chunk[i];
      if (byte != _cr && byte != _lf) {
        _afterCr = false;
        continue;
      }
      if (byte == _lf && _afterCr) {
        // The LF of a CR LF whose CR ended the line already (maybe in the previous chunk).
        _afterCr = false;
        start = i + 1;
        continue;
      }
      _afterCr = byte == _cr;
      if (!_append(chunk, start, i)) return;
      _endLine();
      if (_stopped) return;
      start = i + 1;
    }
    _append(chunk, start, chunk.length);
  }

  /// Adds `chunk[start, end)` to the current line; false when the event grew past the limit.
  bool _append(List<int> chunk, int start, int end) {
    if (end > start) {
      _eventBytes += end - start;
      if (_eventBytes > _limit) {
        _stop();
        return false;
      }
      _line.add(
        chunk is Uint8List
            ? Uint8List.sublistView(chunk, start, end)
            : chunk.sublist(start, end),
      );
    }
    return true;
  }

  void _stop() {
    _stopped = true;
    _line.clear();
    _out.addError(EventStreamTooLarge(_limit));
    _out.close();
  }

  void _endLine() {
    final bytes = _line.takeBytes();
    // A decoder drops a byte order mark at the start of what it decodes (Dart's, and the
    // browser's), but the standard drops one at the start of the stream only: count them here,
    // decode what follows them, and put back all but the stream's first.
    var boms = 0;
    while (bytes.length >= (boms + 1) * 3 &&
        bytes[boms * 3] == 0xEF &&
        bytes[boms * 3 + 1] == 0xBB &&
        bytes[boms * 3 + 2] == 0xBF) {
      boms++;
    }
    final rest = _utf8.convert(Uint8List.sublistView(bytes, boms * 3));
    final kept = _first && boms > 0 ? boms - 1 : boms;
    _first = false;
    final line = kept == 0 ? rest : '${'﻿' * kept}$rest';
    if (line.isEmpty) {
      _dispatch();
      return;
    }
    if (line.startsWith(':')) {
      _out.add(const Heartbeat());
      return;
    }
    final colon = line.indexOf(':');
    final String field;
    var value = '';
    if (colon < 0) {
      field = line;
    } else {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
    }
    switch (field) {
      case 'event':
        _type = value;
      case 'data':
        if (_hasData) _data.write('\n');
        _data.write(value);
        _hasData = true;
      case 'id':
        if (!value.contains('\u0000')) _lastId = value;
      case 'retry':
        if (value.isNotEmpty && value.codeUnits.every(_isDigit)) {
          final ms = int.tryParse(value);
          if (ms != null) _out.add(RetryHint(Duration(milliseconds: ms)));
        }
    }
  }

  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

  void _dispatch() {
    _eventBytes = 0;
    final hasData = _hasData;
    final data = _data.toString();
    final type = _type;
    _data.clear();
    _hasData = false;
    _type = '';
    // A block without a `data:` line is not dispatched (an `event:` or an `id:` alone); a `data:`
    // with nothing after it is an event whose data is empty.
    if (!hasData) return;
    _out.add(
      ServerEvent(
        data,
        type: type.isEmpty ? 'message' : type,
        id: _lastId.isEmpty ? null : _lastId,
      ),
    );
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_stopped) return;
    _out.addError(error, stackTrace);
  }

  @override
  void close() {
    if (_stopped) return;
    _stopped = true;
    // What follows the last blank line is an incomplete event: it is dropped.
    _out.close();
  }
}
