// TransportAdapter: a real Dio that sends through an HttpTransport (a FakeTransport here). Plain
// test(), not testWidgets: Dio starts its interceptor chain with Timer.run.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const base = 'https://api.example.com';

Dio dioOver(FakeTransport transport) =>
    Dio()..httpClientAdapter = TransportAdapter(transport);

TransportResponse ok([String body = '']) => fakeResponse(200, body: body);

Future<DioException> dioFailure(Future<Object?> future) async {
  try {
    await future;
  } on DioException catch (error) {
    return error;
  }
  fail('the request should have failed');
}

final class _Rejection implements Exception {}

void main() {
  group('the memo of a logical request', () {
    test(
      'options fetched again share one memo; another request has its own',
      () async {
        final transport = FakeTransport((_, _) => ok());
        final dio = dioOver(transport);
        final options = RequestOptions(path: '$base/x');
        await dio.fetch<String>(options);
        await dio.fetch<String>(options);
        await dio.get<String>('$base/x');

        final memos = [
          for (final sent in transport.requests) sent.request.memo,
        ];
        expect(memos[0], isNotNull);
        expect(memos[1], same(memos[0]));
        expect(memos[2], isNot(same(memos[0])));
        expect(options.extra[TransportMemo.key], same(memos[0]));
      },
    );

    test('the sends of dio_smart_retry share one memo', () async {
      final transport = FakeTransport.script([
        fakeResponse(503),
        fakeResponse(503),
        fakeResponse(200),
      ]);
      final dio = dioOver(transport);
      dio.interceptors.add(
        RetryInterceptor(
          dio: dio,
          retries: 3,
          retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
        ),
      );
      await dio.get<String>('$base/x');
      final memos = [for (final sent in transport.requests) sent.request.memo];
      expect(memos, hasLength(3));
      expect(memos[0], isNotNull);
      expect(memos, everyElement(same(memos[0])));
    });

    test('a memo the caller put in extra is the one used', () async {
      final transport = FakeTransport((_, _) => ok());
      final memo = TransportMemo();
      await dioOver(transport).get<String>(
        '$base/x',
        options: Options(extra: {TransportMemo.key: memo}),
      );
      expect(transport.requests.single.request.memo, same(memo));
    });
  });

  test('a response is mapped: status, message, headers, body', () async {
    final transport = FakeTransport(
      (request, body) => TransportResponse(
        statusCode: 404,
        headers: const {'x-a': 'b', 'content-type': 'text/plain'},
        body: Stream<List<int>>.value(utf8.encode('nope')),
        reasonPhrase: 'Not Found',
      ),
    );
    final response = await dioOver(
      transport,
    ).get<String>('$base/x', options: Options(validateStatus: (_) => true));
    expect(response.statusCode, 404);
    expect(response.statusMessage, 'Not Found');
    expect(response.headers.value('x-a'), 'b');
    expect(response.data, 'nope');
  });

  test('method, url and headers reach the transport', () async {
    final transport = FakeTransport((request, body) => ok());
    await dioOver(transport).get<Object?>(
      '$base/items?page=2',
      options: Options(headers: {'x-a': 'b', 'x-n': 3}),
    );
    final sent = transport.requests.single;
    expect(sent.method, 'GET');
    expect(sent.url, Uri.parse('$base/items?page=2'));
    expect(sent.headers['x-a'], 'b');
    expect(sent.headers['x-n'], '3');
    expect(sent.request.body, isNull);
    expect(sent.request.bodyStream, isNull);
  });

  test('bytes round trip as the exact body', () async {
    final transport = FakeTransport((request, body) => ok());
    final bytes = Uint8List.fromList([0, 1, 2, 250, 255]);
    await dioOver(transport).post<Object?>(
      '$base/blob',
      data: bytes,
      options: Options(contentType: 'application/octet-stream'),
    );
    final sent = transport.requests.single;
    expect(sent.body, bytes);
    expect(sent.request.replayable, isTrue);
    expect(sent.request.body, isNotNull);
  });

  test('JSON map data becomes bytes', () async {
    final transport = FakeTransport((request, body) => ok());
    await dioOver(transport).post<Object?>('$base/x', data: {'a': 1});
    final sent = transport.requests.single;
    expect(jsonDecode(sent.text), {'a': 1});
    expect(sent.request.body, isNotNull);
    expect(sent.lowerHeaders['content-type'], contains('application/json'));
  });

  test('FormData becomes bytes with the multipart boundary', () async {
    final transport = FakeTransport((request, body) => ok());
    await dioOver(
      transport,
    ).post<Object?>('$base/upload', data: FormData.fromMap({'name': 'value'}));
    final sent = transport.requests.single;
    expect(
      sent.lowerHeaders['content-type'],
      startsWith('multipart/form-data; boundary='),
    );
    final boundary = sent.lowerHeaders['content-type']!.split('boundary=').last;
    expect(sent.text, contains('--$boundary'));
    expect(sent.text, contains('name="name"'));
    expect(sent.request.body, isNotNull);
    expect(sent.request.replayable, isTrue);
  });

  test('a stream body is a bodyStream, and not replayable', () async {
    final transport = FakeTransport((request, body) => ok());
    await dioOver(transport).post<Object?>(
      '$base/stream',
      data: Stream<List<int>>.value(utf8.encode('hello')),
      options: Options(headers: {Headers.contentLengthHeader: 5}),
    );
    final sent = transport.requests.single;
    expect(sent.request.bodyStream, isNotNull);
    expect(sent.request.body, isNull);
    expect(sent.request.replayable, isFalse);
    expect(sent.request.contentLength, 5);
    expect(sent.text, 'hello');
  });

  test('Options.extra reaches the attributes', () async {
    final transport = FakeTransport((request, body) => ok());
    await dioOver(transport).get<Object?>(
      '$base/x',
      options: Options(extra: {'app.role': 'admin', transportReplayKey: true}),
    );
    final attributes = transport.requests.single.request.attributes;
    expect(attributes['app.role'], 'admin');
    expect(attributes[transportReplayKey], true);
  });

  group('abort', () {
    test('a cancelled token reaches the transport as abortTrigger', () async {
      final started = Completer<void>();
      final transport = FakeTransport((request, body) {
        started.complete();
        return Completer<TransportResponse>().future;
      });
      final token = CancelToken();
      final pending = dioOver(
        transport,
      ).get<Object?>('$base/slow', cancelToken: token);
      final failed = dioFailure(pending);
      await started.future;
      expect(transport.requests.single.abortable, isTrue);
      token.cancel('stop');
      final error = await failed;
      expect(error.type, DioExceptionType.cancel);
      expect(CancelToken.isCancel(error), isTrue);
      expect(transport.abortCount, 1);
    });

    test('a request with no cancel token has no abortTrigger', () async {
      final transport = FakeTransport((request, body) => ok());
      await dioOver(transport).get<Object?>('$base/x');
      expect(transport.requests.single.abortable, isFalse);
    });
  });

  group('failures', () {
    test(
      'each TransportFailure becomes a DioException that carries it',
      () async {
        final expected = <TransportFailure, DioExceptionType>{
          const TransportAborted(): DioExceptionType.cancel,
          const TransportUnsent(): DioExceptionType.connectionError,
          const TransportUntrusted(): DioExceptionType.badCertificate,
          const TransportTimedOut(): DioExceptionType.receiveTimeout,
          const TransportBroken(): DioExceptionType.unknown,
        };
        for (final entry in expected.entries) {
          final transport = FakeTransport.script([entry.key]);
          final error = await dioFailure(
            dioOver(transport).get<Object?>('$base/x'),
          );
          expect(error.type, entry.value, reason: '${entry.key}');
          expect(
            identical(error.error, entry.key),
            isTrue,
            reason: '${entry.key}',
          );
        }
      },
    );

    test('any other error keeps the same object in error', () async {
      final rejection = _Rejection();
      final transport = FakeTransport((request, body) => throw rejection);
      final error = await dioFailure(
        dioOver(transport).get<Object?>('$base/x'),
      );
      expect(error.type, DioExceptionType.unknown);
      expect(identical(error.error, rejection), isTrue);
    });
  });

  group('retries', () {
    test('a retried read calls the transport again', () async {
      final transport = FakeTransport.script([
        const TransportBroken(),
        ok('fine'),
      ]);
      final dio = dioOver(transport);
      dio.interceptors.add(
        RetryInterceptor(
          dio: dio,
          retries: 3,
          retryDelays: const [Duration.zero],
          retryEvaluator: (error, attempt) => error.error is TransportBroken,
        ),
      );
      final response = await dio.get<String>('$base/x');
      expect(response.data, 'fine');
      expect(transport.requests, hasLength(2));
    });

    test('a retried write with a body sends the same bytes again', () async {
      final transport = FakeTransport.script([const TransportBroken(), ok()]);
      final dio = dioOver(transport);
      dio.interceptors.add(
        RetryInterceptor(
          dio: dio,
          retries: 3,
          retryDelays: const [Duration.zero],
          retryEvaluator: (error, attempt) => true,
        ),
      );
      await dio.post<Object?>('$base/x', data: {'a': 1});
      expect(transport.requests, hasLength(2));
      expect(transport.requests[0].text, transport.requests[1].text);
      expect(transport.requests[1].text, isNotEmpty);
    });

    test('a write behind WriteGuard is never sent twice', () async {
      final transport = FakeTransport.script([const TransportBroken(), ok()]);
      final dio = dioOver(transport);
      dio.interceptors.add(
        RetryInterceptor(
          dio: dio,
          retries: 3,
          retryDelays: const [Duration.zero],
          retryEvaluator: WriteGuard.readsOnly((error, attempt) => true),
        ),
      );
      WriteGuard.install(dio);
      final error = await dioFailure(
        dio.put<Object?>('$base/me', data: {'a': 1}),
      );
      expect(error.error, isA<TransportBroken>());
      expect(transport.requests, hasLength(1));
    });

    test('a read behind WriteGuard is retried', () async {
      final transport = FakeTransport.script([const TransportBroken(), ok()]);
      final dio = dioOver(transport);
      dio.interceptors.add(
        RetryInterceptor(
          dio: dio,
          retries: 3,
          retryDelays: const [Duration.zero],
          retryEvaluator: WriteGuard.readsOnly((error, attempt) => true),
        ),
      );
      WriteGuard.install(dio);
      final response = await dio.get<Object?>('$base/x');
      expect(response.statusCode, 200);
      expect(transport.requests, hasLength(2));
    });
  });

  test('close does nothing: the transport still works', () async {
    final transport = FakeTransport((request, body) => ok());
    final adapter = TransportAdapter(transport);
    adapter.close(force: true);
    final dio = Dio()..httpClientAdapter = adapter;
    expect((await dio.get<Object?>('$base/x')).statusCode, 200);
  });
}
