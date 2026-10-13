// DioHttpClient: a Dio as an http.Client. Plain test(), not testWidgets: Dio starts its interceptor
// chain with Timer.run, which only a real event loop runs.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:fespalier/fespalier.dart'
    show FutureProvider, ProviderContainer;
import 'package:fespalier_dio/client.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

final url = Uri.parse('https://api.example.com/items');

void main() {
  test('a non-2xx answer comes back as a response, not an exception', () async {
    final adapter = FakeAdapter(
      (options, _) async => jsonAnswer({'error': 'nope'}, 404),
    );
    final client = DioHttpClient(dioOver(adapter));
    final response = await client.get(url);
    expect(response.statusCode, 404);
    expect(jsonDecode(response.body), {'error': 'nope'});
    expect(response.headers['content-type'], contains('application/json'));
    final server = await client.get(url);
    expect(server.statusCode, 404);
  });

  test('the body streams, chunk by chunk', () async {
    final adapter = FakeAdapter((options, _) async {
      final chunks = Stream<Uint8List>.fromIterable([
        Uint8List.fromList(utf8.encode('one,')),
        Uint8List.fromList(utf8.encode('two,')),
        Uint8List.fromList(utf8.encode('three')),
      ]);
      return ResponseBody(chunks, 200);
    });
    final client = DioHttpClient(dioOver(adapter));
    final streamed = await client.send(http.Request('GET', url));
    expect(streamed.statusCode, 200);
    final seen = await streamed.stream.toList();
    expect(seen, hasLength(3));
    expect(utf8.decode(seen.expand((c) => c).toList()), 'one,two,three');
  });

  test('method, headers and body reach the adapter', () async {
    final adapter = FakeAdapter((options, _) async => emptyAnswer(201));
    final client = DioHttpClient(dioOver(adapter));
    final response = await client.post(
      url,
      headers: {'x-a': 'b'},
      body: 'hello',
    );
    expect(response.statusCode, 201);
    final options = adapter.requests.single;
    expect(options.method, 'POST');
    expect(options.uri, url);
    expect(options.headers['x-a'], 'b');
  });

  test('a Range header passes through, and a 206 is the answer', () async {
    final adapter = FakeAdapter(
      (options, _) async => ResponseBody.fromString(
        'tial',
        206,
        headers: {
          'content-range': ['bytes 4-7/8'],
        },
      ),
    );
    final client = DioHttpClient(dioOver(adapter));
    final response = await client.get(url, headers: {'Range': 'bytes=4-'});
    expect(adapter.requests.single.headers['Range'], 'bytes=4-');
    expect(response.statusCode, 206);
    expect(response.headers['content-range'], 'bytes 4-7/8');
    expect(response.body, 'tial');
  });

  test('the Dio interceptors run on the way out', () async {
    final adapter = FakeAdapter((options, _) async => emptyAnswer(200));
    final dio = dioOver(adapter);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['authorization'] = 'Bearer from-interceptor';
          handler.next(options);
        },
      ),
    );
    await DioHttpClient(dio).get(url);
    expect(
      adapter.requests.single.headers['authorization'],
      'Bearer from-interceptor',
    );
  });

  test(
    'WriteGuard runs: a write a retrier would send again is sent once',
    () async {
      final adapter = FakeAdapter(
        (options, _) async => throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        ),
      );
      final dio = dioOver(adapter);
      dio.interceptors.add(
        RetryInterceptor(
          dio: dio,
          retries: 3,
          retryDelays: const [Duration.zero],
        ),
      );
      WriteGuard.install(dio);
      final client = DioHttpClient(dio);
      await expectLater(
        client.put(url, body: 'x'),
        throwsA(isA<http.ClientException>()),
      );
      expect(adapter.sent, 1, reason: 'a write is never retried');
      // A read goes round again.
      adapter.requests.clear();
      await expectLater(client.get(url), throwsA(isA<http.ClientException>()));
      expect(adapter.sent, greaterThan(1));
    },
  );

  test(
    'a failure that is not a cancel is a ClientException that names the URL',
    () async {
      final adapter = FakeAdapter(
        (options, _) async => throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
        ),
      );
      final client = DioHttpClient(dioOver(adapter));
      try {
        await client.get(url);
        fail('should throw');
      } on http.ClientException catch (error) {
        expect(error.uri, url);
        expect(error.message, contains('connectionTimeout'));
      }
    },
  );

  test(
    'an Abortable request whose trigger fires fails with RequestAbortedException',
    () async {
      final sawCancel = Completer<void>();
      final started = Completer<void>();
      final adapter = FakeAdapter((options, cancelFuture) {
        started.complete();
        unawaited(cancelFuture?.then(sawCancel.complete));
        return Completer<ResponseBody>().future;
      });
      final client = DioHttpClient(dioOver(adapter));
      final trigger = Completer<void>();
      final pending = client.send(
        http.AbortableRequest('GET', url, abortTrigger: trigger.future),
      );
      final failed = expectLater(
        pending,
        throwsA(isA<http.RequestAbortedException>()),
      );
      await started.future;
      trigger.complete();
      await failed;
      await sawCancel.future;
    },
  );

  test('ref.abortable(DioHttpClient(dio)) aborts with its provider', () async {
    final started = Completer<void>();
    final outcome = Completer<Object>();
    final adapter = FakeAdapter((options, _) {
      started.complete();
      return Completer<ResponseBody>().future;
    });
    final dio = dioOver(adapter);
    final load = FutureProvider.autoDispose<void>((ref) async {
      final client = ref.abortable(DioHttpClient(dio));
      try {
        await client.get(url);
      } on Object catch (error) {
        outcome.complete(error);
        rethrow;
      }
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final subscription = container.listen(load, (_, _) {});
    await started.future;
    subscription.close();
    await container.pump();
    expect(await outcome.future, isA<http.RequestAbortedException>());
  });

  test('close() does nothing: the Dio still works', () async {
    final adapter = FakeAdapter((options, _) async => emptyAnswer(200));
    final dio = dioOver(adapter);
    DioHttpClient(dio).close();
    final res = await dio.get<String>(url.toString());
    expect(res.statusCode, 200);
  });
}
