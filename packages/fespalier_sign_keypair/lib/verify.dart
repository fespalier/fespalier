/// Checking a device-signed request the way a server does (since 0.21.0): pure Dart, with no
/// plugin, so a demo server and a test can verify the requests `DeviceSigner` signs. Since the
/// release after 0.25.0 it follows Authkestra's device-signature profile v1 (RFC-014): issuer
/// keys by `kid` (ES256, EdDSA, RS256), an `att` object with `status` and `role`, the profile's
/// refusal codes, and [DeviceRefusals] to answer them.
library;

export 'src/refusals.dart' show DeviceRefusalAction, DeviceRefusals;

export 'src/profile.dart' show DeviceSignatureProfile;
export 'src/verify.dart'
    show
        DeviceSignatureError,
        DeviceSignatureInvalid,
        VerifiedDeviceRequest,
        profileIssuerAlgorithms,
        roleOfAttestation,
        userPresentRole,
        verifyDeviceSignature;
