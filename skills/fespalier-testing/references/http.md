# Testing Dio and `package:http` with `fespalier_dio`

Since 0.9.0. A test of a `data.dart` or an `action.dart` that goes over HTTP needs no network and no sleeping: a **fake
`HttpClientAdapter`** under Dio, a **`MockClient`** under `package:http`, and **zero delays** in the retriers. What the
package does is explained in [`fespalier-data`](../../fespalier-data/references/http.md); this page is the traps of
testing it, and a test of each piece that compiles.

| Trap                                                                      | What to do                                                                                                                                                                                                                                  |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Dio's chain starts with `Timer.run`, so a request never moves in a test   | A plain `test()` (a real event loop) works as it is. In `testWidgets`, `pumpAndSettle()` runs it, and to look at a request that is held open use `await tester.pump(Duration.zero)`: a bare `pump()` does not elapse the zero-length timers |
| A request that nobody answers is a test that hangs                        | Answer from the adapter at once, or hold it on a `Completer` you complete yourself. `cancelFuture` (the adapter's third argument) completes when the request's `CancelToken` is cancelled, so it is how a test sees a cancellation          |
| `MockClient` does not abort by itself                                     | "It is the handler's responsibility": race `(request as Abortable).abortTrigger` and throw `RequestAbortedException`, as a real client does. `ref.abortable(mock)` hands the handler an `AbortableRequest`                                  |
| `MockClient`'s responses carry no `request`, and are new objects          | Not a problem for `WriteGuardClient`, which marks what it saw by identity. A test that wants `response.request` sets `request:` on the `StreamedResponse` itself                                                                            |
| `dio_smart_retry` waits 1 s, 3 s and 5 s, and `RetryClient` 500 ms and up | Make the delays a provider and override it with zero: `retryDelays: const [Duration.zero]`, `RetryClient.withDelays(inner, const [Duration.zero])`. They still await a real zero-length timer, so these tests are plain `test()`            |
| A write must be sent **once**                                             | Count the requests the adapter or the `MockClient` handler saw, not what the caller got: the caller gets the first error either way                                                                                                         |
| A test that leaves a `ProviderContainer` open                             | `addTearDown(container.dispose)`: the `dio` provider closes its client in `onDispose`, and `ref.abortable` fires its trigger there                                                                                                          |

```yaml
# pubspec.yaml dependencies
  dio: ^5.7.0
  dio_smart_retry: ^7.0.1
  http: ^1.5.0
```

```dart
// lib/api.dart
import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_dio/http.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';

/// How long the retriers wait between attempts. A test overrides it with zero.
final retryDelays = Provider<List<Duration>>(
  (ref) => const [Duration(seconds: 1), Duration(seconds: 3)],
);

/// Dio: reads are retried, writes never are.
final dio = Provider<Dio>((ref) {
  final client = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
  client.interceptors.add(
    RetryInterceptor(
      dio: client,
      retries: 2,
      retryDelays: ref.watch(retryDelays),
      retryEvaluator: WriteGuard.readsOnly(
        DefaultRetryEvaluator(defaultRetryableStatuses).evaluate,
      ),
    ),
  );
  WriteGuard.install(client); // the last call: it goes first
  ref.onDispose(client.close);
  return client;
});

/// The client under the retry client: a test overrides it with a MockClient.
final httpInner = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// package:http, with the same policy.
final httpClient = Provider<http.Client>((ref) {
  final client = RetryClient.withDelays(
    WriteGuardClient(ref.watch(httpInner)),
    ref.watch(retryDelays),
    when: WriteGuardClient.readsOnly(),
    whenError: WriteGuardClient.readErrorsOnly(
      (error, stackTrace) => error is http.ClientException,
    ),
  );
  ref.onDispose(client.close);
  return client;
});
```

```dart
// test/http_test.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart' show Override;
import 'package:fespalier_dio/http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_app/api.dart';

/// A Dio adapter that answers each request with the next status of [statuses] (the last one
/// repeats), and keeps the requests: no network, no sleeping.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.statuses);

  final List<int> statuses;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final status = statuses[requests.length.clamp(0, statuses.length - 1)];
    requests.add(options);
    return ResponseBody.fromString('{}', status);
  }

  @override
  void close({bool force = false}) {}
}

ProviderContainer container([List<Override> overrides = const []]) {
  final c = ProviderContainer(
    overrides: [
      retryDelays.overrideWithValue(const [Duration.zero, Duration.zero]),
      ...overrides,
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('Dio', () {
    test('a write that gets a 503 is sent once, and a read is sent again', () async {
      final adapter = FakeAdapter([503, 503, 200]);
      final client = container().read(dio)..httpClientAdapter = adapter;

      await expectLater(
        client.put<Object?>('/me'),
        throwsA(
          isA<DioException>().having((e) => e.response?.statusCode, 'status', 503),
        ),
      );
      expect(adapter.requests, hasLength(1));

      adapter.requests.clear();
      final read = await client.get<Object?>('/items');
      expect(read.statusCode, 200);
      expect(adapter.requests, hasLength(3));
    });

    test('a write with an Idempotency-Key may be sent again', () async {
      final adapter = FakeAdapter([503, 200]);
      final client = container().read(dio)..httpClientAdapter = adapter;

      final response = await client.post<Object?>(
        '/orders',
        options: Options(headers: {'Idempotency-Key': 'order-1'}),
      );

      expect(response.statusCode, 200);
      expect(adapter.requests, hasLength(2));
    });
  });

  group('package:http', () {
    test('a write that gets a 503 is sent once, and a read is sent again', () async {
      final seen = <String>[];
      final inner = MockClient((request) async {
        seen.add(request.method);
        return http.Response('', seen.length < 3 ? 503 : 200);
      });
      final client = container([httpInner.overrideWithValue(inner)]).read(httpClient);

      expect((await client.post(Uri.https('api.example.com', '/orders'))).statusCode, 503);
      expect(seen, ['POST']);

      seen.clear();
      expect((await client.get(Uri.https('api.example.com', '/items'))).statusCode, 200);
      expect(seen, ['GET', 'GET', 'GET']);
    });

    test('leaving a page aborts its request: a MockClient that races the trigger', () async {
      final started = Completer<void>();
      final inner = MockClient.streaming((request, body) async {
        started.complete();
        await (request as http.Abortable).abortTrigger;
        throw http.RequestAbortedException(request.url);
      });
      final outcome = Completer<Object>();
      final load = FutureProvider.autoDispose<void>((ref) async {
        final client = ref.abortable(inner); // before the first await
        try {
          await client.get(Uri.https('api.example.com', '/items'));
        } on Object catch (error) {
          outcome.complete(error);
        }
      });
      final c = container();
      final subscription = c.listen(load, (_, _) {});
      await started.future;

      subscription.close(); // the page is gone
      await c.pump();

      expect(await outcome.future, isA<http.RequestAbortedException>());
    });
  });
}
```
