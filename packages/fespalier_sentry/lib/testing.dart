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
    // After `configure`'s own, so a span is recorded as the SDK would send it.
    final earlier = options.beforeSendSpan;
    options.beforeSendSpan = (span) {
      final scrubbed = earlier?.call(span);
      return scrubbed is Future<void>
          ? scrubbed.then((_) => _spans.add(span))
          : _spans.add(span);
    };
    hub = Hub(options);
    if (options.traceLifecycle == SentryTraceLifecycle.stream) {
      // What `Sentry.init` installs in a streaming SDK (its setup integration is not exported), and
      // a plain `Hub` never runs integrations: without it `SentryHttpClient` and `sentry_dio`
      // make no span in a test (since 0.19.0). `StreamingInstrumentationSpanFactory` and
      // `SentryOptions.spanFactory` are `@internal`, and exist unchanged from 9.26.0.
      // ignore: invalid_use_of_internal_member
      options.spanFactory = StreamingInstrumentationSpanFactory(hub);
    }
  }

  /// The options the hub was built with.
  final SentryFlutterOptions options;

  /// The transport: it keeps every envelope.
  final RecordingTransport transport;

  /// The hub to give `FespalierSentry(hub:)`, `FespalierSentry.navigatorObserver(hub:)`,
  /// `SentryHttpClient(hub:)` or `dio.addSentry(hub:)`. With `traceLifecycle` set to `stream` in
  /// [RecordingSentry.new]'s `configure`, the HTTP clients make streamed spans (since 0.19.0).
  late final Hub hub;

  final List<SentrySpanV2> _spans = [];

  /// The spans of `traceLifecycle: stream` that ended, in the order they ended (since 0.19.0), as
  /// they stand after `beforeSendSpan`: a span is recorded there, so nothing is flushed and no
  /// timer runs. The SDK gets to it a few microtasks after the span ends: pump a frame first.
  List<SentrySpanV2> get spans => List.unmodifiable(_spans);

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
  ///
  /// Streamed spans (since 0.19.0) follow, one line per segment and per child of it, each segment
  /// in the order it ended and its children in the order they ended:
  ///
  ///     segment <sentry.op> <name> status=<ok|error>[ ttid][ ttfd]
  ///       span <sentry.op> <name> status=<ok|error>
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
    return [...lines, ..._streamedLines()];
  }

  List<String> _streamedLines() {
    String op(SentrySpanV2 s) => '${s.attributes['sentry.op']?.value}';
    String status(SentrySpanV2 s) => 'status=${s.status.value}';
    SentrySpanV2 segmentOf(SentrySpanV2 s) {
      var top = s;
      for (var up = top.parentSpan; up != null; up = top.parentSpan) {
        top = up;
      }
      return top;
    }

    final lines = <String>[];
    for (final segment in _spans.where((s) => s.parentSpan == null)) {
      final children = _spans
          .where(
            (s) => s.parentSpan != null && identical(segmentOf(s), segment),
          )
          .toList();
      bool has(String key) =>
          children.any((c) => c.attributes.containsKey(key));
      lines.add(
        'segment ${op(segment)} ${segment.name} ${status(segment)}'
        '${has('app.vitals.ttid.value') ? ' ttid' : ''}'
        '${has('app.vitals.ttfd.value') ? ' ttfd' : ''}',
      );
      for (final child in children) {
        lines.add('  span ${op(child)} ${child.name} ${status(child)}');
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
