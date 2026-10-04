// The smallest correct wiring of Sentry, otel_zone and fespalier's telemetry, and the order it has
// to happen in:
//
//  1. Sentry starts first and runs everything else in its `appRunner`: it brings up the binding,
//     `FlutterError.onError`, `PlatformDispatcher.onError` (and `runZonedGuarded` on the web) and
//     its native SDK, so crashes are Sentry's. That is why `OtelZone.runGuarded` is not used here:
//     its zone would send an uncaught async error to Talker only, and Sentry would never see it.
//     `SENTRY_DSN` is empty by default, so nothing is sent: pass
//     `--dart-define=SENTRY_DSN=https://...` to see events in your project.
//  2. WidgetsFlutterBinding.ensureInitialized() and runApp both run inside Sentry's zone: Flutter
//     records the zone that created the binding and warns when runApp comes from another one.
//  3. start() brings the OpenTelemetry SDK up (it never throws), with the fespalier resource
//     attributes.
//  4. The two sinks are installed together before the router is built, so the first navigation is
//     reported. FespalierSentry is errors first: every error and crash tagged with the route, the
//     file and the action, a breadcrumb per page change, release health. Next to FespalierOtel each
//     event also carries the OpenTelemetry trace id (`otel.trace_id`), so an error links to its
//     trace. Screen-load transactions are the opt-in (`FespalierSentry(tracing: true)`, and
//     `tracing: true` in `FespalierSentry.configure`): this app already has its traces in OTel.
//
// Run it against a collector: `flutter run --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=http://...`.
// In debug, FespalierOtel.endpoint() points at http://localhost:4318 (http://10.0.2.2:4318 on an
// Android emulator), and in release without the define it is '' and nothing is sent.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_otel/fespalier_otel.dart';
import 'package:fespalier_sentry/fespalier_sentry.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:otel_zone/otel_zone.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app.g.dart';

final OtelZone observability = OtelZone(
  OtelZoneConfig(
    serviceName: 'telemetry-example',
    endpoint: FespalierOtel.endpoint(),
    deploymentEnvironmentName: 'development',
  ),
);

/// Where Sentry sends. Empty: Sentry is off, and so is everything `FespalierSentry` does.
const String sentryDsn = String.fromEnvironment('SENTRY_DSN');

Future<void> main() => SentryFlutter.init(
  (options) => FespalierSentry.configure(options, dsn: sentryDsn),
  appRunner: () async {
    WidgetsFlutterBinding.ensureInitialized();
    await observability.start(
      serviceVersion: '1.0.0',
      resourceAttributes: {...FespalierOtel.resourceAttributes},
    );
    FespalierTelemetry.install(
      FespalierTelemetry.combine([
        FespalierSentry(),
        FespalierOtel(isReady: () => observability.isReady),
      ]),
    );
    runApp(
      ProviderScope(
        // Both are null when the SDK never came up, hence the `?`.
        observers: [?observability.riverpodObserver()],
        child: MaterialApp.router(
          routerConfig: AppRoutes.router(
            observers: [
              // On the web release health needs it; it makes no transaction.
              if (kIsWeb) FespalierSentry.navigatorObserver(),
              ?observability.routeObserver(),
            ],
          ),
        ),
      ),
    );
  },
);
