/// Token-free device-signed sessions for `fespalier_auth` (since 0.21.0), the scheme Webank runs
/// in production: no OIDC provider, no access token, no refresh token, no `Authorization` header.
///
/// Enrolling a device is signing in. The device holds an ambient key (never prompts) and, where
/// the platform has a secure element, a user-present key (a biometric or the device credential).
/// Enrolment sends their public keys and a one-time code, and the server answers with an
/// attestation per key: a JWS that binds the key (`cnf.jkt`) and means nothing without a fresh
/// signature from it. Every request then carries the attestation and a per-send signature over
/// its method, path, query and exact body bytes, so a stolen request cannot be replayed, changed
/// or redirected.
///
/// ```dart
/// final backend = DeviceAuthBackend(
///   server: ShopDeviceServer(transport), // your endpoints: DeviceAuthServer
///   keys: DeviceKeys.device(),
///   profile: const DeviceSignatureProfile(audience: 'https://api.example.com'),
/// );
/// // AuthConfig(backend: backend, transport: transport, apiOrigins: [api]) in startup.dart
/// ```
///
/// Renewal replaces refresh (a silent proof of possession, single-flight, lazy), a restore signs
/// the user out as `keyLost` when the key is gone or swapped, and signing out revokes the device
/// on the server before it deletes both keys. `package:fespalier_sign_keypair/verify.dart` has
/// `verifyDeviceSignature` for a demo server and tests, and
/// `package:fespalier_sign_keypair/testing.dart` a `FakeDeviceAuthServer`.
library;

export 'src/attestation.dart' show Attestation;
export 'src/backend.dart' show DeviceAuthBackend;
export 'src/credential.dart' show DeviceCredential;
export 'src/errors.dart' show UserPresenceRefused;
export 'src/keys.dart' show DeviceKeys;
export 'src/profile.dart' show DeviceSignatureProfile;
export 'src/server.dart'
    show
        CompleteEnrolment,
        DeviceAuthServer,
        DeviceEnrolment,
        EnrolmentChallenge,
        EnrolmentStart,
        RoleChallenge;
export 'src/signer.dart'
    show
        DeviceRefusal,
        DeviceRefusalClassifier,
        DeviceSigner,
        KeyRolePolicy,
        webankRefusals;
