import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

/// CBOR major types, the high three bits of an initial byte.
const int majorUint = 0;

/// Negative integer.
const int majorNint = 1;

/// Byte string.
const int majorBstr = 2;

/// Text string.
const int majorTstr = 3;

/// Array.
const int majorArray = 4;

/// Map.
const int majorMap = 5;

/// Tag.
const int majorTag = 6;

/// `null`.
const int cborNull = 0xf6;

/// The empty map, the only unprotected header a message may carry.
const int cborEmptyMap = 0xa0;

/// A CBOR writer for the few shapes COSE needs, always in the shortest form (RFC 8949 §4.2.1),
/// which is what cratestack's writer produces and its parser demands.
final class CborWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  /// The bytes written so far.
  Uint8List toBytes() => _out.toBytes();

  /// A head: [major] and the argument [arg], shortest form.
  void head(int major, int arg) {
    final initial = major << 5;
    if (arg < 24) {
      _out.addByte(initial | arg);
    } else if (arg <= 0xff) {
      _out
        ..addByte(initial | 24)
        ..addByte(arg);
    } else if (arg <= 0xffff) {
      _out
        ..addByte(initial | 25)
        ..add(_be(arg, 2));
    } else if (arg <= 0xffffffff) {
      _out
        ..addByte(initial | 26)
        ..add(_be(arg, 4));
    } else {
      _out
        ..addByte(initial | 27)
        ..add(_be(arg, 8));
    }
  }

  /// An integer (unsigned or negative).
  void integer(int value) {
    if (value >= 0) {
      head(majorUint, value);
    } else {
      head(majorNint, -1 - value);
    }
  }

  /// A byte string.
  void bstr(List<int> bytes) {
    head(majorBstr, bytes.length);
    _out.add(bytes);
  }

  /// A text string (UTF-8).
  void tstr(String text) {
    final bytes = utf8.encode(text);
    head(majorTstr, bytes.length);
    _out.add(bytes);
  }

  /// `null`.
  void nul() => _out.addByte(cborNull);

  /// A single raw byte (an already-encoded one-byte item, such as the empty map).
  void raw(int byte) => _out.addByte(byte);

  /// Already-encoded bytes.
  void rawBytes(List<int> bytes) => _out.add(bytes);

  static Uint8List _be(int value, int width) {
    final out = Uint8List(width);
    var rest = value;
    for (var i = width - 1; i >= 0; i--) {
      out[i] = rest % 256;
      rest ~/= 256;
    }
    return out;
  }
}

/// A strict reader: the shortest head only, definite lengths only, and every failure is a
/// [CoseRejected] (never a distinguishing message, a verifier must not be an oracle).
final class CborReader {
  /// A reader over [buf].
  CborReader(this.buf);

  /// The bytes read.
  final Uint8List buf;

  /// The next position.
  int pos = 0;

  /// Whether every byte has been read.
  bool get isAtEnd => pos == buf.length;

  int _byte() {
    if (pos >= buf.length) throw const CoseRejected();
    return buf[pos++];
  }

  int _word(int width) {
    var value = 0;
    for (var i = 0; i < width; i++) {
      value = value * 256 + _byte();
    }
    return value;
  }

  /// A head: `(major, arg)`; a non-minimal head is refused.
  (int, int) head() {
    final initial = _byte();
    final major = initial >> 5;
    final info = initial & 0x1f;
    final int arg;
    switch (info) {
      case < 24:
        arg = info;
      case 24:
        arg = _minimal(_word(1), 24);
      case 25:
        arg = _minimal(_word(2), 0x100);
      case 26:
        arg = _minimal(_word(4), 0x10000);
      case 27:
        // 64-bit arguments above 2^63 do not fit an int, and nothing in COSE needs them.
        final high = _word(4);
        if (high >= 0x80000000) throw const CoseRejected();
        arg = _minimal(high * 0x100000000 + _word(4), 0x100000000);
      default:
        throw const CoseRejected();
    }
    return (major, arg);
  }

  static int _minimal(int arg, int floor) {
    if (arg < floor) throw const CoseRejected();
    return arg;
  }

  /// The argument of a head of [major].
  int expect(int major) {
    final (found, arg) = head();
    if (found != major) throw const CoseRejected();
    return arg;
  }

  /// One byte that must equal [expected].
  void expectByte(int expected) {
    if (_byte() != expected) throw const CoseRejected();
  }

  /// The range of a byte string's content, within [buf].
  (int, int) bstrRange() {
    final len = expect(majorBstr);
    final start = pos;
    if (len > buf.length - pos) throw const CoseRejected();
    pos += len;
    return (start, pos);
  }

  /// An unsigned integer.
  int uint() => expect(majorUint);

  /// An integer, unsigned or negative.
  int integer() {
    final (major, arg) = head();
    if (major == majorUint) return arg;
    if (major == majorNint) return -1 - arg;
    throw const CoseRejected();
  }
}
