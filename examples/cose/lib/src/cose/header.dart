import 'dart:typed_data';

import 'cbor.dart';
import 'errors.dart';

/// COSE algorithm ids this library speaks: ESP256 (ECDSA P-256 with SHA-256, a 64-byte `r||s`).
/// `-7` (ES256) and `-8` (the polymorphic EdDSA) are refused, as cratestack does.
const int algEsp256 = -9;

/// Ed25519 (`-19`). Only a verifier supplied by the caller can check it.
const int algEd25519 = -19;

/// The length of a `kid` on the wire.
const int kidLength = 8;

const int _labelAlg = 1;
const int _labelKid = 4;
const int _labelCwtClaims = 15;
const int _claimIat = 6;
const int _claimCti = 7;

/// Whether [length] is a `cti` length the header carries: a counter of 1 to 4 bytes, or 16
/// random bytes.
bool ctiLengthOk(int length) => (length >= 1 && length <= 4) || length == 16;

/// The protected header, byte for byte as cratestack builds it: a definite map, labels
/// ascending, shortest-form integers. A request is `{1: alg, 4: kid, 15: {6: iat, 7: cti}}`, a
/// response (when [claims] is null) `{1: alg, 4: kid}`.
Uint8List encodeProtected(
  int alg,
  List<int> kid, {
  ({int iat, List<int> cti})? claims,
}) {
  final out = CborWriter()
    ..head(majorMap, claims == null ? 2 : 3)
    ..head(majorUint, _labelAlg)
    ..integer(alg)
    ..head(majorUint, _labelKid)
    ..bstr(kid);
  if (claims != null) {
    out
      ..head(majorUint, _labelCwtClaims)
      ..head(majorMap, 2)
      ..head(majorUint, _claimIat)
      ..head(majorUint, claims.iat)
      ..head(majorUint, _claimCti)
      ..bstr(claims.cti);
  }
  return out.toBytes();
}

/// A parsed protected header.
final class ProtectedHeader {
  const ProtectedHeader._(this.alg, this.kid, this.iat, this.cti);

  /// The algorithm id.
  final int alg;

  /// The 8-byte key id.
  final Uint8List kid;

  /// Set for a request.
  final int? iat;

  /// Set for a request.
  final Uint8List? cti;

  /// Whether this header carries the request claims.
  bool get isRequest => iat != null;
}

/// Parses [bytes] strictly: exactly the encoding [encodeProtected] writes, anything else is a
/// [CoseRejected].
ProtectedHeader parseProtected(Uint8List bytes) {
  final reader = CborReader(bytes);
  final entries = reader.expect(majorMap);
  if (entries != 2 && entries != 3) throw const CoseRejected();
  if (reader.uint() != _labelAlg) throw const CoseRejected();
  final alg = reader.integer();
  if (alg != algEsp256 && alg != algEd25519) throw const CoseRejected();
  if (reader.uint() != _labelKid) throw const CoseRejected();
  final (kidStart, kidEnd) = reader.bstrRange();
  if (kidEnd - kidStart != kidLength) throw const CoseRejected();
  final kid = Uint8List.sublistView(bytes, kidStart, kidEnd);
  int? iat;
  Uint8List? cti;
  if (entries == 3) {
    if (reader.uint() != _labelCwtClaims) throw const CoseRejected();
    if (reader.expect(majorMap) != 2 || reader.uint() != _claimIat) {
      throw const CoseRejected();
    }
    iat = reader.uint();
    if (reader.uint() != _claimCti) throw const CoseRejected();
    final (ctiStart, ctiEnd) = reader.bstrRange();
    if (!ctiLengthOk(ctiEnd - ctiStart)) throw const CoseRejected();
    cti = Uint8List.sublistView(bytes, ctiStart, ctiEnd);
  }
  if (!reader.isAtEnd) throw const CoseRejected();
  return ProtectedHeader._(alg, kid, iat, cti);
}
