# fespalier_dio

Dio for [fespalier](https://github.com/fespalier/fespalier) (since 0.9.0): a load whose page is
gone stops, a server's validation error lands under its form field, and a write is never sent twice.
Since 0.21.0 it is also Dio's side of [`fespalier_transport`](../fespalier_transport/README.md):
`DioTransport` sends a transport's requests through your Dio, and `TransportAdapter` lets your Dio send
through a transport chain. It links no `package:http`. fespalier itself is unchanged: no `fsp` change, no
`fespalier:` key, and the same `app.g.dart`. It starts no timer and no listener, and it has no retry policy of
its own (a backoff needs a timer).

The docs cover it in context:
[HTTP clients](https://github.com/fespalier/fespalier/blob/main/docs/http.md). This page is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if
they are the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.24.1
  fespalier_transport:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_transport
      ref: v0.24.1
  fespalier_dio:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_dio
      ref: v0.24.1
```

<!-- x-release-please-end -->

Needs Dart 3.9 and Flutter 3.35 or newer. It depends on `dio` (`^5.7.0`), on `fespalier_transport` (the transport interface and the write rule `WriteGuard` shares with every transport) and, since 0.25.0, on `web` (0.5.0 or newer, below 2.0.0: the browser bindings of the fetch adapter). All are pure Dart, and none brings `http`.

## Libraries

| Library                                    | What is in it                                                                                                                   |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `package:fespalier_dio/fespalier_dio.dart` | `ref.cancelToken()`, `withFieldErrors()`, `WriteGuard`, `WriteNotRetried`, `DioTransport` and `TransportAdapter` (since 0.21.0) |
| `package:fespalier_dio/fetch.dart`         | `FetchHttpClientAdapter` and `webStreamingAdapter()`: a Dio that streams in a browser (since 0.25.0)                              |

The server's validation-error decoders (`fieldErrorsOf`, `FieldErrorsDecoders`, `FieldNames`) are in `package:fespalier/problem.dart`: this library no longer re-exports them. `package:fespalier_dio/client.dart` and `DioHttpClient` (your Dio as an `http.Client`) were removed in 0.21.0: send through `DioTransport` instead, or use `fespalier_http`'s `HttpClientTransport` if you want `package:http`.

## Dio as a transport

`DioTransport(dio)` is an `HttpTransport`: anything that sends through one (a `SessionTransport`, a download, a client of
your own) sends through the app's Dio, its interceptors, `WriteGuard` included.

```dart
final transport = SessionTransport(DioTransport(ref.watch(dio)), ref.watch(authorizer));
final response = await transport.send(TransportRequest(method: 'GET', uri: Uri.parse('https://api.example.com/me')));
```

The response body streams (`ResponseType.stream`) and every status is an answer (`validateStatus: (_) => true`), so a 404
or a 500 comes back as a response. A request made of bytes sends its body as bytes, so an interceptor that sends it again
sends the whole body a second time; a `bodyStream` streams once (its `contentLength` becomes the `content-length`
header). `abortTrigger` cancels a `CancelToken` through a side `then`, with no timer. `attributes` are never sent: they
are copied into `Options.extra`, where a Dio interceptor can read them. A `DioException` becomes a `TransportFailure`
whose `cause` is Dio's error and whose text never names the server:

| `DioExceptionType`                     | Thrown               |
| -------------------------------------- | -------------------- |
| `cancel`                               | `TransportAborted`   |
| `connectionError`, `connectionTimeout` | `TransportUnsent`    |
| `badCertificate`                       | `TransportUntrusted` |
| `sendTimeout`, `receiveTimeout`        | `TransportTimedOut`  |
| `badResponse`, `unknown`               | `TransportBroken`    |

Two cases pass through unchanged: a `TransportFailure` already in `DioException.error`, and an `Exception` an
interceptor rejected with (a session's `AuthRejected`), thrown as that object with its stack trace.

## A Dio that sends through a transport

`TransportAdapter(transport)` is a Dio `HttpClientAdapter`: your own `Dio`, with its interceptors, `dio_smart_retry`
and `WriteGuard`, sends through a transport chain.

```dart
final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
  ..httpClientAdapter = TransportAdapter(
    SessionTransport(WriteGuardTransport(HttpClientTransport(http.Client())), ref.watch(authorizer)),
  );
```

A finalized body (JSON, a form, `FormData`) is collected into bytes, so the transport can sign and replay the exact
bytes; a `Stream` as `data` stays a `bodyStream` and is not replayable. Dio's cancel future is the `abortTrigger`, and
`RequestOptions.extra` becomes the request's `attributes`. A `TransportFailure` becomes a `DioException` with the failure
in `error` (`TransportAborted` a `cancel`, `TransportUnsent` a `connectionError`, `TransportUntrusted` a `badCertificate`, `TransportTimedOut` a
`receiveTimeout`, `TransportBroken` an `unknown`), and any other error the transport throws is wrapped as an `unknown`
`DioException` whose `error` is that same object. Every retry that Dio's retry interceptors perform calls the adapter
again, so a session below it sees every send. `close()` does nothing: the transport belongs to whoever made it.

## Streaming on the web

Dio's own web adapter reads a response with `XMLHttpRequest` into one buffer, so a streamed body (an event stream through
`DioTransport`) arrives in one piece when the server ends it. `package:fespalier_dio/fetch.dart` (since 0.25.0) has
`FetchHttpClientAdapter`, a Dio adapter over the browser's `fetch` that hands each chunk on as it arrives, and
`webStreamingAdapter()`, which is that adapter in a web build and Dio's default adapter everywhere else:

```dart
import 'package:fespalier_dio/fetch.dart';

final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))..httpClientAdapter = webStreamingAdapter();
```

A `CancelToken`, Dio closing the response, cancelling the body subscription and `close(force: true)` of a running request abort
the `fetch` (an abort is a `cancel`; a `fetch` that fails before the headers is a `connectionError`; a request the browser refuses
to build, such as a `GET` with a body, is `unknown`; a failure in the body is a `DioException` in the body stream, not a
`TransportUnsent`). A cancel while the request body is read stops reading it. The adapter ignores `connectTimeout` and
`sendTimeout` (that takes a timer). **`receiveTimeout` is Dio's own and applies to a stream on every adapter**: Dio drops a body
that is quiet for that long, so a Dio that carries an event stream leaves it null (or zero), or the request passes
`Options(receiveTimeout: Duration.zero)`. The browser follows redirects, and the request body is sent in one piece.
`withCredentials` (and `Options.extra['withCredentials']`) works as on Dio's own web adapter. The library imports neither
Flutter nor fespalier. CI runs it in Chromium, Firefox and WebKit with dart2js and dart2wasm (`just fetch-adapter`);
Safari on macOS and iOS is unchecked (`just fetch-adapter-serve` runs the cases by hand, issue #316). The whole story is in
[HTTP clients](https://github.com/fespalier/fespalier/blob/main/docs/http.md#streaming-on-the-web).

## Cancel a load whose page is gone

```dart
// lib/app/products/$id/data.dart
Future<Product> data(Ref ref, {required int id}) async {
  final cancel = ref.cancelToken(); // before the first await
  final res = await ref.watch(dio).get<Map<String, Object?>>('/products/$id', cancelToken: cancel);
  return Product.fromJson(res.data!);
}
```

The token is cancelled in `ref.onDispose`, which runs when the provider is disposed **and** before it rebuilds.

## Server validation errors on a form

```dart
// lib/app/(account)/nickname/action.dart
Future<Profile> action(Ref ref, {required NicknameFields input}) async {
  final res = await ref
      .read(dio)
      .put<Map<String, Object?>>('/me', data: {'nick_name': input.nickname})
      .withFieldErrors(fieldName: (key) => const {'nick_name': 'nickname'}[key] ?? key);
  return Profile.fromJson(res.data!);
}
```

A 400 or 422 whose body is RFC 9457 or RFC 7807 problem details, ASP.NET Core, Laravel, Rails, Spring, JSON:API,
FastAPI or Django REST framework is thrown as the `FieldErrors` a
[`fespalier_forms`](https://github.com/fespalier/fespalier/blob/main/docs/forms.md) form shows under its fields. Anything else is
rethrown as it was. It is an extension on the `Future`, not an interceptor: a form reads a `FieldErrors`, and
an interceptor can only reject with a `DioException`.

## Writes are never retried

```dart
final dio = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
  dio.interceptors.add(
    RetryInterceptor(
      dio: dio,
      retryEvaluator: WriteGuard.readsOnly(DefaultRetryEvaluator(defaultRetryableStatuses).evaluate),
    ),
  );
  WriteGuard.install(dio); // the last call: it goes first
  ref.onDispose(dio.close);
  return dio;
});
```

`WriteGuard` refuses a second send of a write (any method but `GET`, `HEAD`, `OPTIONS` and `TRACE`, unless it carries
an `Idempotency-Key` header) and hands the caller the error of the first, except after a 401, which is what an
authentication refresh sends again. For a transport, `WriteGuardTransport` (in `fespalier_transport`) marks writes by the same rule,
`HttpWrites`, so the two never disagree.
