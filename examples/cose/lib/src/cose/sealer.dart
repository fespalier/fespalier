import 'dart:math';
import 'dart:typed_data';

import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';

import 'binding.dart';
import 'errors.dart';
import 'header.dart';
import 'keys.dart';
import 'tbs.dart';

/// A fresh 16-byte `cti` from the operating system's secure random source.
Uint8List secureCti([Random? random]) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(List<int>.generate(16, (_) => source.nextInt(256)));
}

/// The current time in Unix seconds.
int _systemSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Seals a payload as a COSE_Sign1 that cratestack's envelope layer accepts (ESP256, binding
/// version 2), with a device key behind a [DpopSigner]: the Secure Enclave or the AndroidKeyStore
/// through `SignKeypairSigner`, or `SoftwareDpopSigner` in a test.
///
/// A sealer starts no timer and reads no listener: sealing is one signature per call. Every
/// request is sealed fresh (a new `iat` and `cti`), so a retry of the same call is a new message
/// the server has not seen, under the same `Idempotency-Key` the binding carries.
final class CoseSealer {
  /// A sealer for [signer]'s key. [nowSeconds] and [newCti] are for a test; the defaults are the
  /// wall clock and 16 bytes of `Random.secure()`.
  CoseSealer(
    this.signer, {
    int Function()? nowSeconds,
    Uint8List Function()? newCti,
  }) : _now = nowSeconds ?? _systemSeconds,
       _cti = newCti ?? secureCti;

  /// The key's signer: `sign` takes the Sig_structure and returns a 64-byte `r||s`.
  final DpopSigner signer;

  final int Function() _now;
  final Uint8List Function() _cti;

  Esp256VerifyKey? _identity;

  /// The public half as a verify key: its `kid` goes into every header, its thumbprint names
  /// the key to the server. The key is made on first use by the signer.
  Future<Esp256VerifyKey> identity() async {
    final known = _identity;
    if (known != null) return known;
    return _identity = Esp256VerifyKey.jwk(await signer.publicJwk());
  }

  /// Seals [payload] (the CBOR the unsigned codec would send) for the request [bind].
  /// [iat] and [cti] default to now and a fresh random `cti`.
  Future<Uint8List> sealRequest(
    List<int> payload,
    CoseBinding bind, {
    int? iat,
    List<int>? cti,
  }) async {
    if (bind.response != null) {
      throw const CoseMisuse('sealing a request with a response binding');
    }
    final claims = (iat: iat ?? _now(), cti: cti ?? _cti());
    if (!ctiLengthOk(claims.cti.length)) {
      throw const CoseMisuse('the cti must be 1 to 4 or 16 bytes');
    }
    return await _seal(payload, bind, claims);
  }

  /// Seals [payload] as the response to a request (a server's side, used by tests and by a
  /// fake server): [bind] carries the response link.
  Future<Uint8List> sealResponse(List<int> payload, CoseBinding bind) async {
    if (bind.response == null) {
      throw const CoseMisuse('sealing a response with a request binding');
    }
    return await _seal(payload, bind, null);
  }

  Future<Uint8List> _seal(
    List<int> payload,
    CoseBinding bind,
    ({int iat, List<int> cti})? claims,
  ) async {
    // The audience check first: local misuse is found before the key is touched.
    final aad = externalAad(bind);
    final me = await identity();
    final protected = encodeProtected(algEsp256, me.kid, claims: claims);
    final tbs = sigStructure(
      protected: protected,
      externalAad: aad,
      payload: payload,
    );
    final raw = await signer.sign(tbs);
    final signature = normalizeLowS(raw);
    return sign1Message(
      protected: protected,
      payload: payload,
      signature: signature,
    );
  }
}
