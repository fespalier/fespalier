// The real wiring (what startup() builds, on the platform's own keys) assembles without touching a
// key or the network.
import 'package:device/api.dart';
import 'package:device/device_setup.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'the app signs in with a DeviceAuthBackend, and signs only for its API',
    () {
      final config = authSetup(apiTransport(), store: MemoryTokenStore());
      expect(config.backend, isA<DeviceAuthBackend>());
      expect(config.backend.name, 'device');
      expect(config.apiOrigins, [apiOrigin]);
      expect(demoApi.served, isEmpty);
    },
  );
}
