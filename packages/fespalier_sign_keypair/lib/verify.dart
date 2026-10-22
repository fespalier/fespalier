/// Checking a device-signed request the way a server does (since 0.21.0): pure Dart, with no
/// plugin, so a demo server and a test can verify the requests `DeviceSigner` signs.
library;

export 'src/profile.dart' show DeviceSignatureProfile;
export 'src/verify.dart'
    show
        DeviceSignatureError,
        DeviceSignatureInvalid,
        VerifiedDeviceRequest,
        verifyDeviceSignature;
