// FespalierOtel.endpoint(): where a debug build exports to, and why a release build exports
// nowhere. The rule is `resolveEndpoint`; `endpoint()` feeds it the build's own facts.
import 'package:fespalier_otel/fespalier_otel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

String resolve({
  String defined = '',
  TargetPlatform platform = TargetPlatform.linux,
  bool isWeb = false,
  bool isRelease = false,
}) => FespalierOtel.resolveEndpoint(
  defined: defined,
  platform: platform,
  isWeb: isWeb,
  isRelease: isRelease,
);

void main() {
  test('the dart-define wins, in debug and in release', () {
    expect(resolve(defined: 'https://otel.example'), 'https://otel.example');
    expect(
      resolve(defined: 'https://otel.example', isRelease: true),
      'https://otel.example',
    );
    expect(
      resolve(
        defined: 'http://192.168.1.5:4318',
        platform: TargetPlatform.android,
      ),
      'http://192.168.1.5:4318',
    );
  });

  test('a release build without the define exports nowhere', () {
    expect(resolve(isRelease: true), '');
    expect(resolve(isRelease: true, platform: TargetPlatform.android), '');
    expect(resolve(isRelease: true, isWeb: true), '');
  });

  test('an Android emulator reaches its host at 10.0.2.2', () {
    expect(resolve(platform: TargetPlatform.android), 'http://10.0.2.2:4318');
  });

  test('iOS, desktop and the web use localhost', () {
    expect(resolve(platform: TargetPlatform.iOS), 'http://localhost:4318');
    expect(resolve(platform: TargetPlatform.macOS), 'http://localhost:4318');
    expect(resolve(platform: TargetPlatform.linux), 'http://localhost:4318');
    expect(resolve(platform: TargetPlatform.windows), 'http://localhost:4318');
  });

  test(
    'the web wins over the platform: a browser on Android is not the emulator',
    () {
      expect(
        resolve(platform: TargetPlatform.android, isWeb: true),
        'http://localhost:4318',
      );
    },
  );

  test('endpoint() reads the build: a test run is a debug build on the host', () {
    // No define, not a release build: the host's answer. `flutter test` runs on the VM, whose
    // platform is not Android unless the test says so.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(FespalierOtel.endpoint(), 'http://10.0.2.2:4318');
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(FespalierOtel.endpoint(), 'http://localhost:4318');
  });
}
