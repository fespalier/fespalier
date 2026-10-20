// FespalierOtel.serviceVersion() and buildId(): what `start(serviceVersion:, buildId:)` gets (since
// 0.19.0). The rules are `resolveServiceVersion` and `resolveBuildId`; the two read the build's own
// FLUTTER_BUILD_NAME and FLUTTER_BUILD_NUMBER, which a test run may or may not have.

import 'package:fespalier_otel/fespalier_otel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the service version is the build name, and unknown without one', () {
    expect(FespalierOtel.resolveServiceVersion('1.4.0'), '1.4.0');
    expect(FespalierOtel.resolveServiceVersion(null), 'unknown');
    // otel_zone refuses an empty version, so an empty define is unknown too.
    expect(FespalierOtel.resolveServiceVersion(''), 'unknown');
  });

  test('the build id is the build number, and none without one', () {
    expect(FespalierOtel.resolveBuildId('45'), '45');
    expect(FespalierOtel.resolveBuildId(null), isNull);
    expect(FespalierOtel.resolveBuildId(''), isNull);
  });

  test('the readers always give a version otel_zone accepts', () {
    expect(FespalierOtel.serviceVersion(), isNotEmpty);
  });
}
