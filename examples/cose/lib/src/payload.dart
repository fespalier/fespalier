import 'dart:convert';
import 'dart:typed_data';

import 'cose/cbor.dart';

/// Encodes a JSON-native value (maps with string keys, lists, strings, integers, doubles, booleans,
/// null) as the CBOR the server's codec reads: the payload inside every COSE_Sign1 message.
///
/// The same value always gives the same bytes (a map keeps its insertion order, every head is the
/// shortest), which is what lets an intent be sent again as the very message it was the first time.
Uint8List encodePayload(Object? value) {
  final out = CborWriter();
  _write(out, value);
  return out.toBytes();
}

void _write(CborWriter out, Object? value) {
  switch (value) {
    case null:
      out.nul();
    case bool b:
      out.raw(b ? 0xf5 : 0xf4);
    case int n:
      out.integer(n);
    case double d:
      final bytes = ByteData(9)
        ..setUint8(0, 0xfb)
        ..setFloat64(1, d);
      out.rawBytes(bytes.buffer.asUint8List());
    case String s:
      out.tstr(s);
    case List<Object?> list:
      out.head(majorArray, list.length);
      for (final item in list) {
        _write(out, item);
      }
    case Map<Object?, Object?> map:
      out.head(majorMap, map.length);
      for (final MapEntry(:key, :value) in map.entries) {
        if (key is! String) {
          throw ArgumentError.value(key, 'key', 'a payload key is a string');
        }
        out.tstr(key);
        _write(out, value);
      }
    default:
      throw ArgumentError.value(
        value,
        'value',
        'not JSON-native: ${value.runtimeType}',
      );
  }
}

/// A payload that is not CBOR this decoder reads.
final class PayloadFormatException implements Exception {
  /// A malformed payload.
  const PayloadFormatException(this.reason);

  /// What was wrong.
  final String reason;

  @override
  String toString() => 'PayloadFormatException($reason)';
}

/// Decodes the CBOR of a payload into maps, lists, strings, integers, doubles, booleans, null and
/// byte strings. Tolerant of what a server may send (indefinite lengths, floats), unlike the
/// message reader, which is strict: a payload has been authenticated, or is an unsigned refusal
/// that nothing relies on.
Object? decodePayload(List<int> bytes) {
  final reader = _Reader(Uint8List.fromList(bytes));
  final value = reader.item(0);
  if (!reader.done) throw const PayloadFormatException('trailing bytes');
  return value;
}

const int _maxDepth = 32;

final class _Reader {
  _Reader(this._buf);

  final Uint8List _buf;
  int _pos = 0;

  bool get done => _pos == _buf.length;

  int _byte() {
    if (_pos >= _buf.length) throw const PayloadFormatException('truncated');
    return _buf[_pos++];
  }

  int _word(int width) {
    var value = 0;
    for (var i = 0; i < width; i++) {
      value = value * 256 + _byte();
    }
    return value;
  }

  Uint8List _take(int length) {
    if (length < 0 || length > _buf.length - _pos) {
      throw const PayloadFormatException('truncated');
    }
    final out = Uint8List.sublistView(_buf, _pos, _pos + length);
    _pos += length;
    return out;
  }

  /// The argument of a head, or null for an indefinite length.
  int? _arg(int info) {
    if (info < 24) return info;
    return switch (info) {
      24 => _word(1),
      25 => _word(2),
      26 => _word(4),
      27 => _word(8),
      31 => null,
      _ => throw const PayloadFormatException('reserved head'),
    };
  }

  Object? item(int depth) {
    if (depth > _maxDepth) throw const PayloadFormatException('too deep');
    final initial = _byte();
    final major = initial >> 5;
    final info = initial & 0x1f;
    switch (major) {
      case majorUint:
        return _arg(info) ?? (throw const PayloadFormatException('bad uint'));
      case majorNint:
        final arg =
            _arg(info) ?? (throw const PayloadFormatException('bad nint'));
        return -1 - arg;
      case majorBstr:
        return _chunks(info, majorBstr).expand((c) => c).toList();
      case majorTstr:
        final text = BytesBuilder(copy: false);
        for (final chunk in _chunks(info, majorTstr)) {
          text.add(chunk);
        }
        try {
          return utf8.decode(text.takeBytes());
        } on FormatException {
          throw const PayloadFormatException('bad utf-8');
        }
      case majorArray:
        final count = _arg(info);
        final out = <Object?>[];
        if (count == null) {
          while (_peek() != 0xff) {
            out.add(item(depth + 1));
          }
          _pos++;
        } else {
          for (var i = 0; i < count; i++) {
            out.add(item(depth + 1));
          }
        }
        return out;
      case majorMap:
        final count = _arg(info);
        final out = <String, Object?>{};
        void entry() {
          final key = item(depth + 1);
          if (key is! String) {
            throw const PayloadFormatException('a map key is a string');
          }
          out[key] = item(depth + 1);
        }

        if (count == null) {
          while (_peek() != 0xff) {
            entry();
          }
          _pos++;
        } else {
          for (var i = 0; i < count; i++) {
            entry();
          }
        }
        return out;
      case majorTag:
        _arg(info);
        return item(depth + 1);
      default:
        return switch (info) {
          20 => false,
          21 => true,
          22 || 23 => null,
          25 => _half(_word(2)),
          26 => (ByteData(4)..setUint32(0, _word(4))).getFloat32(0),
          27 =>
            (ByteData(8)
                  ..setUint32(0, _word(4))
                  ..setUint32(4, _word(4)))
                .getFloat64(0),
          _ => throw const PayloadFormatException('unsupported simple value'),
        };
    }
  }

  int _peek() {
    if (_pos >= _buf.length) throw const PayloadFormatException('truncated');
    return _buf[_pos];
  }

  Iterable<Uint8List> _chunks(int info, int major) sync* {
    final length = _arg(info);
    if (length != null) {
      yield _take(length);
      return;
    }
    while (_peek() != 0xff) {
      final head = _byte();
      if (head >> 5 != major) {
        throw const PayloadFormatException('bad chunk');
      }
      final size = _arg(head & 0x1f);
      if (size == null) throw const PayloadFormatException('nested chunk');
      yield _take(size);
    }
    _pos++;
  }

  static double _half(int bits) {
    final sign = bits >> 15 == 1 ? -1.0 : 1.0;
    final exponent = (bits >> 10) & 0x1f;
    final fraction = bits & 0x3ff;
    if (exponent == 0) return sign * fraction * 5.960464477539063e-8;
    if (exponent == 31) {
      return fraction == 0 ? sign * double.infinity : double.nan;
    }
    return sign * (1 + fraction / 1024) * _pow2(exponent - 15);
  }

  static double _pow2(int n) {
    var value = 1.0;
    for (var i = 0; i < n.abs(); i++) {
      value = n >= 0 ? value * 2 : value / 2;
    }
    return value;
  }
}
