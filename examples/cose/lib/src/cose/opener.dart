import 'dart:typed_data';

import 'binding.dart';
import 'cbor.dart';
import 'errors.dart';
import 'header.dart';
import 'keys.dart';
import 'tbs.dart';

/// The default clock skew a request's `iat` is accepted within, seconds.
const int defaultSkewSeconds = 300;

/// A message that opened: signed by one of the keys, bound to the expected context.
final class CoseOpened {
  const CoseOpened({
    required this.payload,
    required this.kid,
    required this.alg,
    required this.key,
    this.iat,
    this.cti,
  });

  /// The CBOR payload.
  final Uint8List payload;

  /// The signer's `kid`.
  final Uint8List kid;

  /// The algorithm.
  final int alg;

  /// The key that verified the message.
  final CoseVerifyKey key;

  /// A request's issue time, Unix seconds.
  final int? iat;

  /// A request's `cti`.
  final Uint8List? cti;
}

/// Opens COSE_Sign1 messages with the keys it holds.
///
/// Strictness follows cratestack's verifier: the exact tag and shape, shortest-form heads, an
/// empty unprotected header, an embedded payload, no trailing byte, the protected header exactly
/// as the writer produces it, the AAD rebuilt from the caller's own context, a low-s ESP256
/// signature. Every failure of the received bytes is the same [CoseRejected]. This opener checks
/// a request's `iat` but keeps no record of `cti`s: replay protection is the server's.
final class CoseOpener {
  /// An opener that trusts [keys]. [nowSeconds] is the clock a request's `iat` is judged by.
  CoseOpener(
    Iterable<CoseVerifyKey> keys, {
    int Function()? nowSeconds,
    this.skewSeconds = defaultSkewSeconds,
  }) : _keys = List<CoseVerifyKey>.unmodifiable(keys),
       _now = nowSeconds ?? _systemSeconds;

  final List<CoseVerifyKey> _keys;
  final int Function() _now;

  /// The seconds a request's `iat` may be off.
  final int skewSeconds;

  static int _systemSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Opens a sealed response with the expected [bind] (a response binding).
  CoseOpened openResponse(Uint8List body, CoseBinding bind) =>
      open(body, [bind], request: false).$1;

  /// Opens a sealed request with the expected [bind] (a request binding).
  CoseOpened openRequest(Uint8List body, CoseBinding bind) =>
      open(body, [bind], request: true).$1;

  /// Opens [body] against the first of [binds] that verifies, and says which. The candidates may
  /// differ only in `contractSha` (a verifier that accepts several digests for one op).
  (CoseOpened, int) open(
    Uint8List body,
    List<CoseBinding> binds, {
    required bool request,
  }) {
    if (binds.isEmpty) throw const CoseRejected();
    for (final bind in binds) {
      if (bind.differsBeyondDigest(binds.first)) {
        throw const CoseMisuse(
          'candidate bindings may differ only in the contract digest',
        );
      }
      if (request == (bind.response != null)) {
        throw CoseMisuse(
          request
              ? 'opening a request with a response binding'
              : 'opening a response with a request binding',
        );
      }
    }
    // Local misuse (an empty audience) is found before any received byte is read.
    final aads = [for (final bind in binds) externalAad(bind)];

    final reader = CborReader(body);
    if (reader.expect(majorTag) != sign1Tag) throw const CoseRejected();
    if (reader.expect(majorArray) != 4) throw const CoseRejected();
    final (pStart, pEnd) = reader.bstrRange();
    if (pEnd == pStart) throw const CoseRejected();
    reader.expectByte(cborEmptyMap);
    final (payStart, payEnd) = reader.bstrRange();
    final (sigStart, sigEnd) = reader.bstrRange();
    if (!reader.isAtEnd) throw const CoseRejected();

    final protectedBytes = Uint8List.sublistView(body, pStart, pEnd);
    final header = parseProtected(protectedBytes);
    if (header.isRequest != request) throw const CoseRejected();
    final payload = Uint8List.sublistView(body, payStart, payEnd);
    final signature = Uint8List.sublistView(body, sigStart, sigEnd);

    CoseVerifyKey? signer;
    var which = -1;
    for (var i = 0; i < aads.length && signer == null; i++) {
      final tbs = sigStructure(
        protected: protectedBytes,
        externalAad: aads[i],
        payload: payload,
      );
      for (final key in _keys) {
        if (key.alg == header.alg &&
            _same(key.kid, header.kid) &&
            key.verify(tbs, signature)) {
          signer = key;
          which = i;
          break;
        }
      }
    }
    if (signer == null) throw const CoseRejected();

    final iat = header.iat;
    if (iat != null && (_now() - iat).abs() > skewSeconds) {
      throw const CoseRejected();
    }
    return (
      CoseOpened(
        payload: Uint8List.fromList(payload),
        kid: Uint8List.fromList(header.kid),
        alg: header.alg,
        key: signer,
        iat: iat,
        cti: header.cti == null ? null : Uint8List.fromList(header.cti!),
      ),
      which,
    );
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
