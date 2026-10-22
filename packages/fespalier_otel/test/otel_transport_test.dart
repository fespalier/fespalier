// OtelTransport on the real dartastic SDK with an in-memory exporter: the CLIENT span of each
// request, its place under the active data span, and what it never records.
import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_otel/fespalier_otel.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

final InMemorySpanExporter exporter = InMemorySpanExporter();

const TelemetrySite dataSite = TelemetrySite(
  'items/\$id/data.dart',
  route: '/items/:id',
);

TransportRequest get(String url, {Map<String, String> headers = const {}}) =>
    TransportRequest(method: 'GET', uri: Uri.parse(url), headers: headers);

Map<String, String> attributesOf(Span span) => {
  for (final attribute in span.attributes.toList())
    attribute.key: '${attribute.value}',
};

Span only(String name) {
  final found = exporter.findSpansByName(name);
  expect(found, hasLength(1), reason: '$name in ${exporter.spanNames}');
  return found.single;
}

void main() {
  setUpAll(() async {
    await OTel.initialize(
      serviceName: 'test',
      serviceVersion: '0.0.1',
      enableLogs: false,
      enableMetrics: false,
      detectPlatformResources: false,
      spanProcessor: SimpleSpanProcessor(exporter),
    );
  });
  setUp(exporter.clear);
  tearDown(() => FespalierTelemetry.install(null));

  test(
    'a request is one CLIENT span with the semantic-convention attributes',
    () async {
      final inner = FakeTransport((_, _) => fakeResponse(200));
      final transport = OtelTransport(inner);
      await transport.send(
        get(
          'https://api.example.com/items/42?token=secret-query#fragment',
          headers: {'Authorization': 'Bearer secret-header'},
        ),
      );
      final span = only('GET');
      expect(span.kind, SpanKind.client);
      expect(span.instrumentationScope.name, 'fespalier');
      expect(attributesOf(span), {
        'fespalier.operation': 'http',
        'http.request.method': 'GET',
        'server.address': 'api.example.com',
        'server.port': '443',
        'url.scheme': 'https',
        'url.path': '/items/42',
        'http.response.status_code': '200',
      });
      // Nothing the request carried reaches the span.
      final everything = attributesOf(span).toString() + span.name;
      expect(everything, isNot(contains('secret')));
      expect(everything, isNot(contains('fragment')));
      expect(span.spanEvents ?? const [], isEmpty);
      expect(
        span.parentSpanContext,
        anyOf(isNull, predicate((c) => !(c! as SpanContext).isValid)),
      );
    },
  );

  test(
    'an explicit port is the span\'s port, and http defaults to 80',
    () async {
      final transport = OtelTransport(
        FakeTransport((_, _) => fakeResponse(204)),
      );
      await transport.send(get('http://localhost:8090/health'));
      await transport.send(get('http://cdn.example.com/a'));
      final ports = exporter.spans.map((s) => attributesOf(s)['server.port']);
      expect(ports, ['8090', '80']);
    },
  );

  test(
    'inside a data span the request is its child, after an await too',
    () async {
      final otel = FespalierOtel();
      final token = otel.start(
        const TelemetryStart(TelemetryOp.data, site: dataSite),
      );
      final transport = OtelTransport(
        FakeTransport((_, _) => fakeResponse(200)),
      );
      final done = Completer<void>();
      otel.within(token, () async {
        await Future<void>.delayed(Duration.zero);
        await transport.send(get('https://api.example.com/items/5'));
        done.complete();
        return null;
      });
      await done.future;
      otel.end(token, const TelemetryEnd(TelemetryOutcome.data));
      final data = only(r'data items/$id/data.dart');
      final request = only('GET');
      expect(request.parentSpanContext?.spanId, data.spanContext.spanId);
      expect(request.spanContext.traceId, data.spanContext.traceId);
    },
  );

  test(
    'a 4xx or 5xx answer is an error span with the status as its type',
    () async {
      final transport = OtelTransport(
        FakeTransport((_, _) => fakeResponse(503)),
      );
      final response = await transport.send(get('https://api.example.com/x'));
      expect(
        response.statusCode,
        503,
        reason: 'the answer still reaches the caller',
      );
      final span = only('GET');
      expect(attributesOf(span)['http.response.status_code'], '503');
      expect(attributesOf(span)['error.type'], '503');
      expect(span.status, SpanStatusCode.Error);
    },
  );

  test(
    'no answer: the failure class is the type, its text is not kept',
    () async {
      final failure = TransportUnsent(
        StateError('connection to secret-host refused'),
        Uri.parse('https://secret-host.example/x'),
      );
      final transport = OtelTransport(FakeTransport.script([failure]));
      await expectLater(
        transport.send(get('https://api.example.com/x')),
        throwsA(same(failure)),
      );
      final span = only('GET');
      expect(attributesOf(span)['error.type'], 'TransportUnsent');
      expect(
        attributesOf(span).containsKey('http.response.status_code'),
        isFalse,
      );
      expect(span.status, SpanStatusCode.Error);
      expect(
        '${attributesOf(span)} ${span.statusDescription}',
        isNot(contains('secret')),
      );
    },
  );

  group('trace headers', () {
    test('only an origin in propagateTo gets traceparent', () async {
      final inner = FakeTransport((_, _) => fakeResponse(200));
      final transport = OtelTransport(
        inner,
        propagateTo: [Uri.parse('https://api.example.com')],
      );
      await transport.send(
        get('https://api.example.com/a', headers: {'X-A': '1'}),
      );
      await transport.send(get('https://cdn.example.com/b'));
      await transport.send(get('http://api.example.com/c'));
      final sent = inner.requests;
      final span = exporter.spans.first;
      expect(
        sent[0].lowerHeaders['traceparent'],
        '00-${span.spanContext.traceId.hexString}-${span.spanContext.spanId.hexString}-01',
      );
      expect(sent[0].headers['X-A'], '1');
      expect(sent[1].lowerHeaders.containsKey('traceparent'), isFalse);
      expect(sent[2].lowerHeaders.containsKey('traceparent'), isFalse);
    });

    test('by default none is added', () async {
      final inner = FakeTransport((_, _) => fakeResponse(200));
      await OtelTransport(inner).send(get('https://api.example.com/a'));
      expect(
        inner.requests.single.lowerHeaders.containsKey('traceparent'),
        isFalse,
      );
      expect(
        inner.requests.single.lowerHeaders.containsKey('tracestate'),
        isFalse,
      );
    });
  });

  group('re-sends and attributes', () {
    test('an auth replay is its own span with a resend count', () async {
      final inner = FakeTransport((_, _) => fakeResponse(200));
      final transport = OtelTransport(inner);
      await transport.send(get('https://api.example.com/a'));
      await transport.send(
        get(
          'https://api.example.com/a',
        ).copyWith(attributes: {transportReplayKey: true}),
      );
      final spans = exporter.spans;
      expect(spans, hasLength(2));
      expect(
        attributesOf(spans[0]).containsKey('http.request.resend_count'),
        isFalse,
      );
      expect(attributesOf(spans[1])['http.request.resend_count'], '1');
    });

    test('the memo of a logical request counts its sends', () async {
      final inner = FakeTransport((_, _) => fakeResponse(200));
      final transport = OtelTransport(inner);
      final memo = TransportMemo();
      final request = get(
        'https://api.example.com/a',
      ).copyWith(attributes: {TransportMemo.key: memo});
      await transport.send(request);
      await transport.send(request);
      await transport.send(request);
      final counts = exporter.spans.map(
        (s) => attributesOf(s)['http.request.resend_count'],
      );
      expect(counts, [null, '1', '2']);
    });

    test('the attributes reach the inner transport as they were', () async {
      final inner = FakeTransport((_, _) => fakeResponse(200));
      final memo = TransportMemo();
      final request = get('https://api.example.com/a').copyWith(
        attributes: {TransportMemo.key: memo, transportReplayKey: true, 'x': 1},
      );
      await OtelTransport(
        inner,
        propagateTo: [Uri.parse('https://api.example.com')],
      ).send(request);
      final seen = inner.requests.single.request.attributes;
      expect(seen[TransportMemo.key], same(memo));
      expect(seen[transportReplayKey], true);
      expect(seen['x'], 1);
    });
  });

  test(
    'until the SDK is ready the request goes through untouched, with no span',
    () async {
      var ready = false;
      final inner = FakeTransport((_, _) => fakeResponse(200));
      final transport = OtelTransport(
        inner,
        isReady: () => ready,
        propagateTo: [Uri.parse('https://api.example.com')],
      );
      final request = get('https://api.example.com/a');
      await transport.send(request);
      expect(identical(inner.requests.single.request, request), isTrue);
      expect(exporter.spans, isEmpty);
      ready = true;
      await transport.send(request);
      expect(exporter.spans, hasLength(1));
    },
  );
}
