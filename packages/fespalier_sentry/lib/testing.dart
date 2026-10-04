/// A real Sentry hub whose transport keeps what it would send, for tests (since 0.9.0): no
/// `SentryFlutter.init`, no native SDK, no timer, no network.
///
/// ```dart
/// final sentry = RecordingSentry();
/// FespalierTelemetry.install(FespalierSentry(hub: sentry.hub));
/// // ... navigate, pump ...
/// expect(await sentry.lines(), contains('event StateError operation=action ...'));
/// ```
library;

import 'dart:convert';

import 'package:sentry_flutter/sentry_flutter.dart';

/// A real Sentry hub over `SentryFlutterOptions` with a transport that records envelopes instead
/// of sending them (since 0.9.0): the SDK's own naming, scope binding, measurements, event
/// processors and envelopes are what a test reads, not a mock's idea of them.
///
/// The SDK hands an event to its transport a few microtasks after the call that captured it, so
/// pump a frame (`await tester.pump()`) before reading [sent] or [lines].
final class RecordingSentry {
  /// [configure] runs after the test defaults: a made-up DSN (nothing is sent: the transport is
  /// [transport]), `tracesSampleRate` 1.0 and `debug` off. Leave `tracesSampleRate` null in it to
  /// test an app that has not turned Sentry's tracing on.
  RecordingSentry({void Function(SentryFlutterOptions options)? configure})
    : transport = RecordingTransport(),
      options = SentryFlutterOptions(dsn: 'https://key@sentry.invalid/1') {
    options
      ..transport = transport
      ..tracesSampleRate = 1.0;
    configure?.call(options);
    hub = Hub(options);
  }

  /// The options the hub was built with.
  final SentryFlutterOptions options;

  /// The transport: it keeps every envelope.
  final RecordingTransport transport;

  /// The hub to give `FespalierSentry(hub:)`, `FespalierSentry.navigatorObserver(hub:)` or
  /// `dio.addSentry(hub:)`.
  late final Hub hub;

  /// What was sent so far, each event and transaction decoded to its JSON map, oldest first.
  /// A transaction has `"type": "transaction"`.
  Future<List<Map<String, Object?>>> sent() async {
    final decoded = <Map<String, Object?>>[];
    for (final envelope in transport.envelopes) {
      for (final item in envelope.items) {
        final type = item.header.type;
        if (type != 'event' && type != 'transaction') continue;
        final bytes = await item.dataFactory();
        decoded.add(
          Map<String, Object?>.from(
            jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
          ),
        );
      }
    }
    return decoded;
  }

  /// What was sent, one line per transaction, span and event, without timestamps or ids:
  ///
  ///     transaction <op> <name> status=<status>[ ttid][ ttfd]
  ///       span <op> <description> status=<status>
  ///     event <exception type>[ operation=<op>][ route=<route>][ file=<file>][ action=<name>]
  Future<List<String>> lines() async {
    final lines = <String>[];
    for (final item in await sent()) {
      if (item['type'] == 'transaction') {
        final trace = _map(_map(item['contexts'])['trace']);
        final measurements = _map(item['measurements']);
        lines.add(
          'transaction ${trace['op']} ${item['transaction']} '
          'status=${trace['status']}'
          '${measurements.containsKey('time_to_initial_display') ? ' ttid' : ''}'
          '${measurements.containsKey('time_to_full_display') ? ' ttfd' : ''}',
        );
        for (final span in (item['spans'] as List<Object?>? ?? const [])) {
          final s = _map(span);
          lines.add(
            '  span ${s['op']} ${s['description']} status=${s['status']}',
          );
        }
      } else {
        final exceptions = _map(item['exception'])['values'];
        final type = exceptions is List && exceptions.isNotEmpty
            ? _map(exceptions.first)['type']
            : item['message'] != null
            ? 'message'
            : 'event';
        final tags = _map(item['tags']);
        String part(String name, String tag) =>
            tags[tag] == null ? '' : ' $name=${tags[tag]}';
        lines.add(
          'event $type'
          '${part('operation', 'fespalier.operation')}'
          '${part('route', 'fespalier.route')}'
          '${part('file', 'fespalier.file')}'
          '${part('action', 'fespalier.action')}',
        );
      }
    }
    return lines;
  }

  /// The breadcrumbs on the hub's scope, as `<category> <message>` lines, oldest first.
  List<String> get breadcrumbs =>
      rawBreadcrumbs.map((b) => '${b.category} ${b.message}').toList();

  /// The breadcrumbs on the hub's scope, as the SDK holds them, oldest first.
  // `Hub.scope` is `@internal`: it is the one way to read what a hub holds, as Sentry's own tests
  // do.
  // ignore: invalid_use_of_internal_member
  List<Breadcrumb> get rawBreadcrumbs => hub.scope.breadcrumbs;

  /// The scope's tags, as the SDK holds them.
  Map<String, String> get tags =>
      // ignore: invalid_use_of_internal_member
      hub.scope.tags;

  /// The scope's transaction name: what a later event is grouped under.
  String? get transactionName =>
      // ignore: invalid_use_of_internal_member
      hub.scope.transaction;

  /// Closes the hub. A test that built one needs no more than this.
  Future<void> close() => hub.close();

  static Map<String, Object?> _map(Object? value) => value is Map
      ? Map<String, Object?>.from(value)
      : const <String, Object?>{};
}

/// A [Transport] that keeps every envelope it is given and sends nothing.
final class RecordingTransport implements Transport {
  /// The envelopes, oldest first.
  final List<SentryEnvelope> envelopes = [];

  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    envelopes.add(envelope);
    return envelope.header.eventId;
  }
}
