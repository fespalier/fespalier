/// A pure-Dart COSE_Sign1 sealer and opener for CrateStack's signed transport (cratestack 0.15.3,
/// binding version 2), checked byte for byte against cratestack-cose's shared test vectors.
///
/// The wire: every body is `Tag(18)[protected, {}, payload, signature]`; the payload is the CBOR
/// the unsigned codec would send, the protected header is `{1: alg, 4: kid, 15: {6: iat, 7: cti}}`
/// (a response `{1: alg, 4: kid}`), the `kid` is the first 8 bytes of the RFC 9679 thumbprint,
/// and the signature covers `["Signature1", protected, external_aad, payload]` where the
/// external AAD (never sent) binds the audience, the op, its contract digest, the bound headers
/// and, for a response, the request's digest and the status.
library;

export 'binding.dart'
    show
        CoseBinding,
        ResponseLink,
        bindingVersion,
        externalAad,
        requestDigestOf;
export 'errors.dart' show CoseMisuse, CoseRejected;
export 'header.dart'
    show
        ProtectedHeader,
        algEd25519,
        algEsp256,
        ctiLengthOk,
        encodeProtected,
        kidLength,
        parseProtected;
export 'keys.dart' show CoseVerifyKey, Esp256VerifyKey, normalizeLowS;
export 'opener.dart' show CoseOpened, CoseOpener, defaultSkewSeconds;
export 'sealer.dart' show CoseSealer, secureCti;
export 'tbs.dart' show sigStructure, sign1Message, sign1Tag;
export 'thumbprint.dart'
    show ec2P256Thumbprint, kidFromThumbprint, p256CoordinatesOfJwk;
