// The smallest correct wiring of otel_zone and fespalier's telemetry, and the order it has to
// happen in:
//
//  1. The OtelZone is built at the top level, so anything that logs before start-up finishes has a
//     sink to land on.
//  2. The guarded zone opens. WidgetsFlutterBinding.ensureInitialized() and runApp both run inside
//     it: Flutter records the zone that created the binding and warns when runApp comes from
//     another one.
//  3. start() brings the SDK up (it never throws), with the fespalier resource attributes.
//  4. The FespalierOtel sink is installed before the router is built, so the first navigation is a
//     span too. Until then (and in release without an endpoint) fespalier reports nothing.
//
// Run it against a collector: `flutter run --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=http://...`.
// In debug, FespalierOtel.endpoint() points at http://localhost:4318 (http://10.0.2.2:4318 on an
// Android emulator), and in release without the define it is '' and nothing is sent.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_otel/fespalier_otel.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:otel_zone/otel_zone.dart';

import 'app.g.dart';

final OtelZone observability = OtelZone(
  OtelZoneConfig(
    serviceName: 'telemetry-example',
    endpoint: FespalierOtel.endpoint(),
    deploymentEnvironmentName: 'development',
  ),
);

Future<void> main() => guarded(() async {
  WidgetsFlutterBinding.ensureInitialized();
  await observability.start(
    serviceVersion: '1.0.0',
    resourceAttributes: {...FespalierOtel.resourceAttributes},
  );
  FespalierTelemetry.install(
    FespalierOtel(isReady: () => observability.isReady),
  );
  runApp(
    ProviderScope(
      // Both are null when the SDK never came up, hence the `?`.
      observers: [?observability.riverpodObserver()],
      child: MaterialApp.router(
        routerConfig: AppRoutes.router(
          observers: [?observability.routeObserver()],
        ),
      ),
    ),
  );
});

/// `OtelZone.runGuarded` leaves a Flutter web app blank: its body never runs (since 0.8.0, known
/// limitation: otel_zone runGuarded on web; it builds a `ReceivePort` first). Elsewhere it is the
/// zone that catches what nothing else does; on the web the body runs as it is.
Future<void> guarded(Future<void> Function() body) =>
    kIsWeb ? body() : observability.runGuarded(body);
