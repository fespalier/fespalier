// SentryTransport on a real hub with a recording transport: the breadcrumb every request leaves,
// the error event on request, the span with `tracing: true` in both trace lifecycles, and what
// it never records.
import 'package:fespalier_sentry/fespalier_sentry.dart';
import 'package:fespalier_sentry/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

TransportRequest get(
  String url, {
  String method = 'GET',
  Map<String, String> headers = const {},
}) => TransportRequest(method: method, uri: Uri.parse(url), headers: headers);

Future<void> settle() => Future<void>.delayed(Duration.zero);

Object? attr(SentrySpanV2 span, String key) => span.attributes[key]?.value;

void main() {
  late RecordingSentry sentry;
  tearDown(() => sentry.close());

  group('by default (errors first)', () {
    test(
      'a request leaves one breadcrumb: method, URL without its query, status, duration',
      () async {
        sentry = RecordingSentry();
        final inner = FakeTransport((_, _) => fakeResponse(200));
        final transport = SentryTransport(inner, hub: sentry.hub);
        await transport.send(
          get(
            'https://api.example.com/items/5?token=secret-query#frag',
            headers: {'Authorization': 'Bearer secret-header'},
          ),
        );
        await settle();
        final crumb = sentry.rawBreadcrumbs.single;
        expect(crumb.category, 'http');
        expect(crumb.type, 'http');
        expect(crumb.level, SentryLevel.info);
        expect(
          crumb.data,
          containsPair('url', 'https://api.example.com/items/5'),
        );
        expect(crumb.data, containsPair('method', 'GET'));
        expect(crumb.data, containsPair('status_code', 200));
        expect(crumb.data, contains('duration'));
        expect(crumb.toJson().toString(), isNot(contains('secret')));
        expect(crumb.toJson().toString(), isNot(contains('frag')));
        // Nothing else: no transaction, no event, no header.
        expect(await sentry.sent(), isEmpty);
        expect(inner.requests.single.lowerHeaders.keys, ['authorization']);
      },
    );

    test(
      'an error answer is an error-level breadcrumb, and still no event',
      () async {
        sentry = RecordingSentry();
        final transport = SentryTransport(
          FakeTransport((_, _) => fakeResponse(503)),
          hub: sentry.hub,
        );
        final response = await transport.send(get('https://api.example.com/x'));
        expect(response.statusCode, 503);
        await settle();
        expect(sentry.rawBreadcrumbs.single.level, SentryLevel.error);
        expect(
          sentry.rawBreadcrumbs.single.data,
          containsPair('status_code', 503),
        );
        expect(await sentry.sent(), isEmpty);
      },
    );

    test(
      'no response: an error breadcrumb with the class only, the failure rethrown',
      () async {
        sentry = RecordingSentry();
        final failure = TransportUnsent(
          StateError('refused by secret-host'),
          Uri.parse('https://secret-host.example/x'),
        );
        final transport = SentryTransport(
          FakeTransport.script([failure]),
          hub: sentry.hub,
        );
        await expectLater(
          transport.send(get('https://api.example.com/x')),
          throwsA(same(failure)),
        );
        await settle();
        final crumb = sentry.rawBreadcrumbs.single;
        expect(crumb.level, SentryLevel.error);
        expect(crumb.data, containsPair('reason', 'TransportUnsent'));
        expect(crumb.data, isNot(contains('status_code')));
        expect(crumb.toJson().toString(), isNot(contains('secret')));
        expect(await sentry.sent(), isEmpty);
      },
    );

    test(
      'with tracing off there is no span and no trace header, even for a target',
      () async {
        sentry = RecordingSentry();
        await sentry.hub
            .startTransaction('t', 'op', bindToScope: true)
            .finish();
        final inner = FakeTransport((_, _) => fakeResponse(200));
        final transport = SentryTransport(
          inner,
          hub: sentry.hub,
          tracePropagationTargets: [Uri.parse('https://api.example.com')],
        );
        await transport.send(get('https://api.example.com/x'));
        expect(inner.requests.single.lowerHeaders.keys, isEmpty);
      },
    );
  });

  group('captureFailedRequests', () {
    test(
      'a failure and a 5xx are events; a 4xx and an abort are not',
      () async {
        sentry = RecordingSentry();
        final transport = SentryTransport(
          FakeTransport.script([
            fakeResponse(404),
            fakeResponse(500),
            const TransportUnsent('x'),
            const TransportAborted(),
          ]),
          hub: sentry.hub,
          captureFailedRequests: true,
        );
        await transport.send(get('https://api.example.com/a?q=secret'));
        await transport.send(get('https://api.example.com/b?q=secret'));
        await expectLater(
          transport.send(get('https://api.example.com/c')),
          throwsA(isA<TransportUnsent>()),
        );
        await expectLater(
          transport.send(get('https://api.example.com/d')),
          throwsA(isA<TransportAborted>()),
        );
        await settle();
        final events = await sentry.sent();
        expect(events, hasLength(2));
        expect(
          (events[0]['exception'] as Map)['values'].toString(),
          contains('TransportStatusError'),
        );
        expect(
          (events[1]['exception'] as Map)['values'].toString(),
          contains('TransportUnsent'),
        );
        expect(events.toString(), isNot(contains('secret')));
        final request = events[0]['request'] as Map;
        expect(request['url'], 'https://api.example.com/b');
      },
    );
  });

  group('tracing: true, traceLifecycle: static', () {
    test(
      'a request is an http.client span under the screen transaction, without its query',
      () async {
        sentry = RecordingSentry();
        final transport = SentryTransport(
          FakeTransport((_, _) => fakeResponse(200)),
          hub: sentry.hub,
          tracing: true,
        );
        final tx = sentry.hub.startTransaction(
          'screen',
          'ui.load',
          bindToScope: true,
        );
        await transport.send(
          get('https://api.example.com/items/5?token=secret'),
        );
        await transport.send(
          get(
            'https://api.example.com/items/5',
          ).copyWith(attributes: {transportReplayKey: true}),
        );
        await tx.finish();
        await settle();
        final sent = (await sentry.sent()).single;
        final spans = (sent['spans'] as List).cast<Map<String, Object?>>();
        expect(spans, hasLength(2));
        expect(spans[0]['op'], 'http.client');
        expect(spans[0]['description'], 'GET /items/5');
        final data = Map<String, Object?>.from(spans[0]['data'] as Map);
        expect(data, containsPair('http.response.status_code', 200));
        expect(data, containsPair('server.address', 'api.example.com'));
        expect(data, containsPair('url.scheme', 'https'));
        expect(data, containsPair('server.port', 443));
        expect(data.containsKey('http.request.resend_count'), isFalse);
        expect(
          Map<String, Object?>.from(spans[1]['data'] as Map),
          containsPair('http.request.resend_count', 1),
        );
        expect(sent.toString(), isNot(contains('secret')));
      },
    );

    test('a 5xx answer is an error span', () async {
      sentry = RecordingSentry();
      final transport = SentryTransport(
        FakeTransport((_, _) => fakeResponse(502)),
        hub: sentry.hub,
        tracing: true,
      );
      final tx = sentry.hub.startTransaction(
        'screen',
        'ui.load',
        bindToScope: true,
      );
      await transport.send(get('https://api.example.com/x'));
      await tx.finish();
      await settle();
      final span =
          ((await sentry.sent()).single['spans'] as List).single
              as Map<String, Object?>;
      expect(span['status'], isNot('ok'));
    });

    test(
      'with no active span there is no span, and the request still goes',
      () async {
        sentry = RecordingSentry();
        final inner = FakeTransport((_, _) => fakeResponse(200));
        final transport = SentryTransport(
          inner,
          hub: sentry.hub,
          tracing: true,
        );
        await transport.send(get('https://api.example.com/x'));
        expect(inner.requests, hasLength(1));
        await settle();
        expect(await sentry.sent(), isEmpty);
      },
    );

    test('sentry-trace and baggage only for a target origin', () async {
      sentry = RecordingSentry();
      final inner = FakeTransport((_, _) => fakeResponse(200));
      final transport = SentryTransport(
        inner,
        hub: sentry.hub,
        tracing: true,
        tracePropagationTargets: [Uri.parse('https://api.example.com')],
      );
      final tx = sentry.hub.startTransaction(
        'screen',
        'ui.load',
        bindToScope: true,
      );
      await transport.send(
        get('https://api.example.com/a', headers: {'X-A': '1'}),
      );
      await transport.send(get('https://cdn.example.com/b'));
      await transport.send(get('http://api.example.com/c'));
      await tx.finish();
      final sent = inner.requests;
      expect(sent[0].lowerHeaders, contains('sentry-trace'));
      expect(sent[0].headers['X-A'], '1');
      expect(sent[1].lowerHeaders.keys, isNot(contains('sentry-trace')));
      expect(sent[2].lowerHeaders.keys, isNot(contains('sentry-trace')));
    });
  });

  group('tracing: true, traceLifecycle: stream', () {
    test(
      'a request is an http.client span, a child of the active span',
      () async {
        sentry = RecordingSentry(
          configure: (o) => o.traceLifecycle = SentryTraceLifecycle.stream,
        );
        final transport = SentryTransport(
          FakeTransport((_, _) => fakeResponse(200)),
          hub: sentry.hub,
          tracing: true,
        );
        await sentry.hub.startSpan<void>('items', (parent) async {
          await settle();
          await transport.send(
            get('https://api.example.com/items/5?token=secret'),
          );
        });
        await settle();
        final spans = sentry.spans;
        final request = spans.singleWhere(
          (s) => attr(s, 'sentry.op') == 'http.client',
        );
        final parent = spans.singleWhere((s) => s.name == 'items');
        expect(request.name, 'GET /items/5');
        expect(request.parentSpan, same(parent));
        expect(attr(request, 'http.response.status_code'), 200);
        expect(attr(request, 'url.path'), '/items/5');
        expect(request.attributes.toString(), isNot(contains('secret')));
      },
    );
  });

  test(
    'the attributes reach the inner transport as they were, with trace headers added',
    () async {
      sentry = RecordingSentry();
      final inner = FakeTransport((_, _) => fakeResponse(200));
      final memo = TransportMemo();
      final request = get('https://api.example.com/a').copyWith(
        attributes: {TransportMemo.key: memo, transportReplayKey: true, 'x': 1},
      );
      final tx = sentry.hub.startTransaction(
        'screen',
        'ui.load',
        bindToScope: true,
      );
      await SentryTransport(
        inner,
        hub: sentry.hub,
        tracing: true,
        tracePropagationTargets: [Uri.parse('https://api.example.com')],
      ).send(request);
      await tx.finish();
      final seen = inner.requests.single.request.attributes;
      expect(seen[TransportMemo.key], same(memo));
      expect(seen[transportReplayKey], true);
      expect(seen['x'], 1);
    },
  );

  test('the memo of a logical request counts its sends', () async {
    sentry = RecordingSentry();
    final transport = SentryTransport(
      FakeTransport((_, _) => fakeResponse(200)),
      hub: sentry.hub,
      tracing: true,
    );
    final memo = TransportMemo();
    final request = get(
      'https://api.example.com/a',
    ).copyWith(attributes: {TransportMemo.key: memo});
    final tx = sentry.hub.startTransaction(
      'screen',
      'ui.load',
      bindToScope: true,
    );
    await transport.send(request);
    await transport.send(request);
    await tx.finish();
    await settle();
    final spans = ((await sentry.sent()).single['spans'] as List)
        .cast<Map<String, Object?>>();
    expect(spans[0]['data'], isNot(contains('http.request.resend_count')));
    expect(
      Map<String, Object?>.from(spans[1]['data'] as Map),
      containsPair('http.request.resend_count', 1),
    );
  });
}
