// A guard that fails after an `await` reaches Sentry twice in an app with `FespalierSentry` next to
// `SentryFlutter.init` (since 0.21.0): from the sink, which tags it with the route and the file, and
// from the report (`FlutterError.reportError`, which `SentryFlutter.init` listens to). Both carry
// the very same error object, which the SDK's own deduplication (`enableDeduplication`, on by
// default, installed by `Sentry.init`) recognises: one event is sent, the sink's, which comes first.
// A plain `Hub` runs no processor of that kind, so this test goes through `Sentry.init`.
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_sentry/fespalier_sentry.dart';
import 'package:fespalier_sentry/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'support.dart';

/// The events among what [transport] was given.
Future<List<Map<String, Object?>>> events(RecordingTransport transport) async {
  final events = <Map<String, Object?>>[];
  for (final envelope in transport.envelopes) {
    for (final item in envelope.items) {
      if (item.header.type != 'event') continue;
      events.add(await _decode(item));
    }
  }
  return events;
}

Future<Map<String, Object?>> _decode(SentryEnvelopeItem item) async {
  final bytes = await item.dataFactory();
  return Map<String, Object?>.from(
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
  );
}

void main() {
  tearDown(() async {
    FespalierTelemetry.install(null);
    await Sentry.close();
  });

  /// What `Sentry.init` sends when the sink hears [first] and the report then carries [second], both
  /// from a guard that failed after an `await`.
  Future<List<Map<String, Object?>>> sent({
    required Object first,
    required Object second,
    bool deduplicate = true,
  }) async {
    final transport = RecordingTransport();
    await Sentry.init((options) {
      options
        ..dsn = Rig.dsn
        ..transport = transport
        ..enableDeduplication = deduplicate;
    });
    FespalierTelemetry.install(FespalierSentry());
    // The sink: a guard span that ended with the guard's error.
    final token = FespalierTelemetry.begin(
      const TelemetryStart(TelemetryOp.guard, site: guardSite),
    );
    FespalierTelemetry.finish(
      token,
      TelemetryEnd(
        TelemetryOutcome.error,
        error: first,
        stackTrace: StackTrace.current,
        isAsync: true,
      ),
    );
    // The report: what `FlutterErrorIntegration` makes of `FlutterError.reportError`'s details
    // (a ThrowableMechanism around the exception, handled: false).
    await Sentry.captureEvent(
      SentryEvent(
        throwable: ThrowableMechanism(
          Mechanism(type: 'FlutterError', handled: false),
          second,
        ),
      ),
      stackTrace: StackTrace.current,
    );
    await pumpEventQueue();
    return events(transport);
  }

  test('one error object reported twice is one event, the sink\'s', () async {
    final error = StateError('boom');
    final sent_ = await sent(first: error, second: error);
    expect(sent_, hasLength(1));
    final tags = Map<String, Object?>.from(sent_.single['tags']! as Map);
    expect(tags['fespalier.operation'], 'guard');
    expect(tags['fespalier.file'], 'checkout/guard.dart');
  });

  test('with enableDeduplication off, it is two events', () async {
    final error = StateError('boom');
    final sent_ = await sent(first: error, second: error, deduplicate: false);
    expect(sent_, hasLength(2));
  });

  test('two different error objects are two events', () async {
    final sent_ = await sent(
      first: StateError('boom'),
      second: StateError('boom'),
    );
    expect(sent_, hasLength(2));
  });
}
