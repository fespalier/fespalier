# HTTP clients: fespalier_http and fespalier_dio

Since 0.9.0, as `fespalier_dio`; the `package:http` half is `fespalier_http` since 0.15.0. Two packages help the two clients most apps use, [`package:http`](https://pub.dev/packages/http) (`fespalier_http`) and [Dio](https://pub.dev/packages/dio) (`fespalier_dio`), keep three of
fespalier's promises: **a load whose page is gone stops**, **a server's validation error lands under its [form](forms.md)
field**, and **a write is never sent twice**.

Since 0.21.0 they are also the two ways into [`fespalier_transport`](transport.md), the pure-Dart `HttpTransport` interface that `fespalier_auth`, the downloads, the image CDN, the translation source and the maps share: `HttpClientTransport(client)` and `DioTransport(dio)` make a transport out of the client you have, and `TransportClient(transport)` and `TransportAdapter(transport)` make a client out of a transport. [HTTP transport](transport.md#the-interface) has the interface; this page is about the two clients.

Neither package starts a timer or a listener.

Add them next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why). An app that uses `package:http` adds `fespalier_http` and links no Dio; an app that uses Dio adds `fespalier_dio` and links no `package:http`; an app that wants both adds both. Both bring `fespalier_transport`: add it too when you import its types (`WriteGuardTransport`, `TransportRequest`, `HttpCredentials`).

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.22.1
  fespalier_transport:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_transport
      ref: v0.22.1
  fespalier_http:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_http
      ref: v0.22.1
  fespalier_dio:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_dio
      ref: v0.22.1
```

<!-- x-release-please-end -->

`fespalier_http` depends on `http` (`^1.5.0`, the first release with abortable requests) and on `fespalier_transport`; `fespalier_dio` depends on `dio` (`^5.7.0`) and on `fespalier_transport`, and neither brings the other's client (since 0.21.0; `fespalier_dio` brought `fespalier_http` until 0.20.0). Import only the library you use:

| Library                                                | For            | What is in it                                                                                                                             |
| ------------------------------------------------------ | -------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `package:fespalier_http/fespalier_http.dart`           | `package:http` | `ref.abortTrigger()`, `ref.abortable(client)`, `withFieldErrors()`, `HttpClientTransport`, `TransportClient` (since 0.21.0)               |
| `package:fespalier_http/testing.dart`                  | tests          | `FakeHttpClient`                                                                                                                          |
| `package:fespalier_dio/fespalier_dio.dart`             | Dio            | `ref.cancelToken()`, `withFieldErrors()`, `WriteGuard`, `WriteNotRetried`, `DioTransport`, `TransportAdapter`, `DioErrors` (since 0.21.0) |
| `package:fespalier_transport/fespalier_transport.dart` | no client      | `HttpTransport`, `TransportRequest`, `TransportResponse`, `TransportFailure`, `HttpCredentials`, `HttpWrites`, `WriteGuardTransport`      |
| `package:fespalier_transport/testing.dart`             | tests          | `FakeTransport`, `FakeHttpCredentials`, `fakeResponse`                                                                                    |
| `package:fespalier/problem.dart`                       | no client      | `FieldErrorsDecoders`, `FieldNames`, `fieldErrorsOf`: for chopper, or a client of your own                                                |

**Since 0.21.0** `HttpCredentials`, `HttpWrites` and `FakeHttpCredentials` are `fespalier_transport`'s, and `WriteGuardClient` is `WriteGuardTransport` (was `package:fespalier_http` until 0.20.0). The validation decoders are in `package:fespalier/problem.dart` (was `package:fespalier_http/problem.dart`, and re-exported by `fespalier_dio`, until 0.20.0). `package:fespalier_dio/client.dart` and `DioHttpClient` are gone: send through `DioTransport`, or, for code that wants an `http.Client` over a Dio, `TransportClient(DioTransport(dio))` ([Upgrading](migration.md#0210)). **Since 0.15.0** `package:fespalier_dio/http.dart` and `package:fespalier_dio/problem.dart` were gone from `fespalier_dio` ([Upgrading](migration.md#0150)).

Nothing here retries, logs or traces by itself: it has no retry policy of its own (a backoff needs a timer), and the HTTP spans and trace headers come from the instrumentation you add: `OtelTransport` and `SentryTransport` around the transport ([Observability](observability.md)), or `otel_dio` and `sentry_dio` on a Dio.

## Cancelling a load whose page is gone

A `data.dart` runs again when its provider is rebuilt (an invalidation, a changed key) and is dropped when its page is left. The old build's result is thrown away either way, but its request goes on to the end. `ref.cancelToken()` (Dio) and `ref.abortTrigger()` or `ref.abortable(client)` (`package:http`) tie the request to the build that made it. They fire in `ref.onDispose`, which runs when the provider is disposed **and** before it rebuilds.

```dart
// lib/app/products/$id/data.dart
Future<Product> data(Ref ref, {required int id}) async {
  final cancel = ref.cancelToken();  // before the first await
  final res = await ref.watch(dio).get<Map<String, Object?>>('/products/$id', cancelToken: cancel);
  return Product.fromJson(res.data!);
}
```

```dart
// package:http: every request of this build, through one client
Future<Product> data(Ref ref, {required int id}) async {
  final client = ref.abortable(ref.watch(httpClient));  // before the first await
  final res = await client.get(Uri.https('api.example.com', '/products/$id'));
  return Product.fromJson(jsonDecode(res.body) as Map<String, Object?>);
}
// or one request: http.AbortableRequest('GET', url, abortTrigger: ref.abortTrigger())
```

- **Ask before the first `await`.** After the provider is gone (a stale `ref`) `onDispose` would throw, so the token comes back already cancelled and the trigger already fired: the request fails at once instead of running for a page nobody sees.
- **One token serves every request of the build**, and a request that a retrier or an authentication refresh sends
  again keeps it (same options).
- **What the request fails with.** Dio: a `DioException` of type `cancel` whose `error` is `fespalier_dio: the
provider that started this request was disposed`. `package:http`: `RequestAbortedException` ("Request aborted by
  `abortTrigger`"). fespalier's data span has already ended as `disposed`, so with
  [telemetry](observability.md#telemetry) it is not an error, and Riverpod ignores the old build's result.
- **`ref.abortable(client)`** sends each request as its `Abortable` twin (`Request`, `MultipartRequest` or
  `StreamedRequest`, with headers, body and redirect settings). A request that has a trigger of its own is aborted
  by whichever fires first. Closing the wrapper does not close your client. The abort reaches the network only if
  the client under it honours the trigger: `package:http`'s own clients and `RetryClient` do, a `MockClient` leaves
  it to its handler.
- It starts **no timer**: the cancellation runs inside `dispose`, which is synchronous.

## Server validation errors on forms

A [form](forms.md) shows the [`FieldErrors`](actions.md#validate-and-fielderrors) its action threw under the field of the same
name, and `form.error` shows `FieldErrors.message` and the messages of keys that are no field. `withFieldErrors()`
on the action's own `Future` turns the server's answer into that exception, in whichever shape the server sends it:

```dart
// lib/app/(account)/nickname/action.dart
Future<Profile> action(Ref ref, {required NicknameFields input}) async {
  final res = await ref
      .read(dio)
      .put<Map<String, Object?>>('/me', data: {'nick_name': input.nickname, 'age': input.age})
      // 422 {"errors": {"nick_name": ["That nickname is taken"]}} lands under the `nickname` field.
      .withFieldErrors(fieldName: (key) => const {'nick_name': 'nickname'}[key] ?? key);
  return Profile.fromJson(res.data!);
}
```

It is an extension on the `Future`, **not an interceptor** (an interceptor can only reject with a `DioException`, and a form reads a `FieldErrors`), so it works on any `Future<T>` (a retrofit client's `api.updateProfile(...).withFieldErrors()` too), and `package:http` has one on `Future<http.Response>` (it returns the response when there is nothing to throw).

- Use it in an `action.dart`. A `data.dart` that gets a 422 wants its `error.dart`.
- For a client with no `Future` to extend (chopper), `fieldErrorsOf(response.statusCode, response.body)` returns the
  `FieldErrors`, or null, and you throw it.

The rules, in order (`fieldErrorsOf`):

1. Only a status in `statuses` (default 400 and 422).
2. The body is a JSON object: a decoded map, or a `String` or bytes holding one.
3. The `decoder` (default `FieldErrorsDecoders.standard`, below) names the fields. Each field gets the **first**
   message the server gave it, and `fieldName` renames the keys to the fields of the form's record (the first
   wins when two keys end up with one name). A key that is no field shows in `form.error`.
4. A **422** that names no field but says what is wrong in a string `detail` (problem+json) or `message` is a
   `FieldErrors` with only that message. A 400 is never converted like that: a 400 with no field errors is usually
   a bug of the client, which should reach your error reporting.
5. Anything else: the original error is rethrown, the very same object.

| Decoder          | Body (abridged)                                                         | Becomes                                                                                                                                                             |
| ---------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `problemDetails` | RFC 9457 `errors: [{detail, pointer: "#/age"}]`                         | `age: ...`; a pointer is a dotted path (`#/profile/color` is `profile.color`); an entry with no pointer is the message                                              |
| `problemDetails` | RFC 7807 `invalid-params: [{name, reason}]`                             | `name: reason`                                                                                                                                                      |
| `problemDetails` | Spring `errors: [{field, defaultMessage}]`                              | `field: defaultMessage`                                                                                                                                             |
| `errorsMap`      | ASP.NET Core, Laravel, Rails: `errors: {field: [message]}`              | `field: first message` (a `""` or `$` key is the message; the generic `message` of Laravel is not used while fields matched)                                        |
| `jsonApi`        | `errors: [{source: {pointer: "/data/attributes/name"}, detail}]`        | `name: detail` (`/data/attributes/` and `/data/relationships/` are dropped)                                                                                         |
| `fastApi`        | `detail: [{loc: ["body", "age"], msg}]`                                 | `age: msg` (a leading `body`, `query`, `path`, `header` or `cookie` is dropped)                                                                                     |
| `flatMap`        | Django REST framework `{field: [message], non_field_errors: [message]}` | `field: ...`, and `non_field_errors` as the message. Not when `type`, `title`, `status`, `errors` or `detail` is a key, nor for a plain-string `message` or `error` |

Each decoder asks for its exact shape and returns null for anything else, so a body that is not a validation error
is never read as one. `standard` tries them in the order above.

`FieldNames.camelCase` turns `first_name`, `FirstName` and `first-name` into `firstName`, each dotted segment on its
own. It changes case only (`nick_name` becomes `nickName`, not `nickname`), so map a name that differs by more by
hand, as in the sample. A decoder of your own is a `FieldErrors? Function(Object? body)` that gets the body as a map.

## Writes are never retried, over HTTP too

fespalier promises [a write is never retried](actions.md#actiondart-typed-writes): its generated provider does not use Riverpod's retry. A client's retry layer would break that from below (`dio_smart_retry` retries every method by default, and `package:http`'s `RetryClient` retries a 503 for every method). `WriteGuard` (Dio) and `WriteGuardTransport` (any transport, so `package:http` through `TransportClient`) keep the promise. `WriteGuardTransport` was `WriteGuardClient`, a wrapper of an `http.Client`, until 0.20.0.

```dart
final dio = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
  dio.interceptors.add(
    RetryInterceptor(                                    // dio_smart_retry: reads only
      dio: dio,
      retryEvaluator: WriteGuard.readsOnly(DefaultRetryEvaluator(defaultRetryableStatuses).evaluate),
    ),
  );
  WriteGuard.install(dio);                               // the last call: it goes first
  ref.onDispose(dio.close);
  return dio;
});

final httpClient = Provider<http.Client>((ref) {
  final inner = http.Client();
  final client = RetryClient(                            // package:http/retry.dart: reads only
    TransportClient(WriteGuardTransport(HttpClientTransport(inner))), // marks each send
    when: TransportClient.readsOnly(),                   // 503, for reads
    whenError: TransportClient.readErrorsOnly((error, stackTrace) => error is http.ClientException),
  );
  ref.onDispose(client.close);
  ref.onDispose(inner.close);                            // a TransportClient never closes the client under it
  return client;
});
```

- **A write** is any method but `GET`, `HEAD`, `OPTIONS` and `TRACE`, unless it carries an `Idempotency-Key` header
  or `Options(extra: {WriteGuard.idempotent: true})` (a write you know is safe to repeat). `Options(extra:
{WriteGuard.write: true})` makes any request one. `WriteGuardTransport.isWrite(request)` is the same rule, without the
  `extra`, and both call `HttpWrites.isWrite` (in `fespalier_transport` since 0.21.0; `fespalier_http` since 0.15.0), so the two clients cannot disagree about what a write is.
- **`WriteGuard` refuses a second send of a write** and hands the caller the error of the first, so a retrier that is
  not told about writes still cannot repeat one. It must be **first** in the interceptors: it records the error of
  the first send before any interceptor that re-sends sees it. `WriteGuard.install(dio)` puts it there, once, so call
  it after adding the others. With a retrier that is asked "is this retryable?", `WriteGuard.readsOnly(evaluator)`
  answers no for a write before calling yours, so it does not even wait out its delay.
- **A debug build says why**, once per request, with the method and the path (never the host, the query or the
  body):

  ```text
  fespalier_dio: PUT /me failed and was about to be sent again. A write is never retried, so its first error is returned. Give the retry interceptor WriteGuard.readsOnly(...) as its evaluator, or add an Idempotency-Key header to a write that is safe to repeat.
  ```

  A retrier that sits **before** the guard sees the error first and sends the write again before the guard has
  recorded anything: the second send fails with a `DioException` whose `error` is `WriteNotRetried`.

- **One exception: a send after a 401.** The server refused it before running it, so `WriteGuard` allows one more
  send of a write after a 401, once per 401, for a response the client accepted as well (`validateStatus`). The
  session needs it no more: `fespalier_auth`'s `SessionTransport` sends the request again below Dio's adapter, where
  `WriteGuard` does not see it, and marks it `transportReplayKey` in the request's attributes (was
  `SessionInterceptor` and `authReplayKey` until 0.20.0). The exception stays for a refresh of your own.
- **`package:http`.** `WriteGuardTransport` forwards every request unchanged and remembers, by identity, which
  responses and which errors came from a write; `TransportClient.readsOnly()` and
  `TransportClient.readErrorsOnly(whenError)` pass that on to the `RetryClient` (the predicates were
  `WriteGuardClient.readsOnly()` and `readErrorsOnly(...)` until 0.20.0). Put the guard in the transport chain under the
  `TransportClient`, and give the retry client **both** predicates: `RetryClient` retries a 503 for any method
  otherwise. A response that says nothing about its request, and went through no `WriteGuardTransport`, is not retried.
- **Two retry layers multiply.** fespalier already retries a failing `data.dart` ([Retries and reloads](data.md#retries-and-reloads)), and an HTTP retrier under it multiplies the attempts. Keep one: the data retry with no HTTP retrier, or an HTTP retrier for reads with `data_retry: none` (or a `ProviderScope(retry:)` that returns null).

## One seam for any client

Since 0.21.0 the seam is `HttpTransport` ([the interface](transport.md#the-interface)), not `package:http`'s `Client` (it was `http.Client` from 0.15.0 to 0.20.0, and `DioHttpClient` made a Dio one). One method, `send(TransportRequest)`, answers a `TransportResponse` whose body streams, and throws a `TransportFailure` when no answer came. A session, a write guard, a download, the image CDN, the translation source and the maps' packs all take an `HttpTransport`, so none of them cares which client is under it. Whatever you already have becomes one:

| You have                                                                      | Make a transport with                                | Notes                                                                                                                                                               |
| ----------------------------------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| an `http.Client` (`IOClient`, `cronet_http`, `cupertino_http`, `RetryClient`) | `HttpClientTransport(client)` (`fespalier_http`)     | honours `abortTrigger` as `package:http` does. Whether an abort reaches the network through `cupertino_http` is **not checked** here: test it before you rely on it |
| a `Dio`                                                                       | `DioTransport(dio)` (`fespalier_dio`)                | everything goes through your Dio and its interceptors, `WriteGuard` included                                                                                        |
| nothing yet, in a test                                                        | `FakeTransport` (`fespalier_transport/testing.dart`) | answers from a handler or a script, honours an abort (no timer), records the requests                                                                               |

And the other way round, for code written for a client:

| You have             | Make a client with                                                     | Notes                                                                                           |
| -------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| a transport chain    | `TransportClient(chain)` (`fespalier_http`)                            | an `http.Client`: `ref.abortable(...)`, `RetryClient`, any package that takes a client          |
| a transport chain    | `Dio()..httpClientAdapter = TransportAdapter(chain)` (`fespalier_dio`) | your Dio, its interceptors and a retrier, sending through the chain                             |
| a handler, in a test | `FakeHttpClient` (`fespalier_http/testing.dart`)                       | answers from a handler, honours an abort (no timer), records the requests and counts the aborts |

Each pair is a bridge, not a wrapper around a wrapper: `TransportClient(HttpClientTransport(client))` sends through `client` and adds nothing. What a bridge changes is spelled out below. Neither closes what it was given (`close()` does nothing): the client or the Dio belongs to the provider that made it, so close it in `ref.onDispose`.

**What a request becomes** (`TransportClient`). An `http.Request` (which `get`, `post`, `put`, `patch` and `delete` make) goes as bytes, so a session can sign its exact body and send it again whole after a 401 and a renewal. An `http.MultipartRequest` is finalized once into bytes (with the boundary in its `content-type`), so it is replayable too. Any other request, an `http.StreamedRequest`, which is what `RetryClient` sends, goes as a body stream that can be read once: the session sends it once, and the caller gets the 401 as a response, after the renewal, so its next attempt works. `TransportAdapter` does the same for Dio: a finalized body (JSON, a form, `FormData`) is collected into bytes; a `Stream` as `data` stays a stream. Before 0.16.0 every body streamed through `DioHttpClient`, and a request with a body that got a 401 failed with `ClientException: fespalier_dio: unknown`.

**What a failure becomes.** [A `TransportFailure`](transport.md#failures) is one of `TransportAborted`, `TransportUnsent`, `TransportTimedOut`, `TransportUntrusted`, `TransportPortal` and `TransportBroken`. `HttpClientTransport` reads an `http.RequestAbortedException` as aborted, a `TimeoutException` as timed out, a refused connection, an unknown host or an unreachable network as unsent (from the text of the error, since the package also builds for the web), a refused TLS certificate (`HandshakeException`, `TlsException`, `CertificateException`; **not on the web**, where the browser does not tell it from any other failed request) as untrusted, and every other `http.ClientException` as broken. `DioTransport` reads Dio's `cancel` as aborted, `connectionError` and `connectionTimeout` as unsent, `badCertificate` as untrusted, `sendTimeout` and `receiveTimeout` as timed out, and `badResponse` and `unknown` as broken; a status is never an error to it (`validateStatus: (_) => true`, the body streams). The way back: `TransportClient` throws `RequestAbortedException` for an aborted send and an `http.ClientException` (its message never names the server) for any other failure, and `TransportAdapter` throws a `DioException` with the failure in `error` (a `cancel`, a `connectionError`, a `badCertificate`, a `receiveTimeout` or an `unknown`). A refused certificate is its own kind because a client must not read it as being offline ([Failures](transport.md#failures)). Code that must not see Dio types reads `DioErrors.toTransport(error)`, which turns a `DioException` back into the failure, or into a `TransportStatusError` for a 4xx or a 5xx (Dio throws those), and anything else is returned as it was.

**The memo.** A session remembers things about one logical request across its sends (the user it was made for, a refusal, the renewals it spent): the [memo](transport.md#the-memo). `TransportAdapter` keeps it in the `RequestOptions`, which a Dio retrier sends again, so every retry of one request shares it. `TransportClient` keeps one per `http.BaseRequest` object, and `RetryClient` sends a **copy** each time, so each copy is a new logical request there: the protection that a request is never sent again without the session it was made with does not follow a `RetryClient`'s copies. [The wrapping order](#the-wrapping-order) says what stops it instead.

## The wrapping order

Four layers can sit between a `data.dart` and the network: the abort, a retrier, the session and the write guard. Since 0.21.0 the session and the write guard are transports, so the order is a transport chain with a client bridge above it. This is the order that works with every one of them, proved by `packages/fespalier_auth/test/wrapping_order_test.dart` (the session and the guard), `packages/fespalier_dio/test/wrapping_order_test.dart` and `session_retry_test.dart` (Dio's retrier above the adapter) and `packages/fespalier_http/test/transport_client_test.dart` (`RetryClient` above the bridge):

```dart
// AuthConfig(transport: ...): the guard sits next to the network
final transport = WriteGuardTransport(HttpClientTransport(inner));

final httpClient = Provider<http.Client>((ref) {
  return RetryClient(
    TransportClient(ref.watch(authTransport)),  // SessionTransport(transport, authorizer)
    when: TransportClient.readsOnly(),
    whenError: TransportClient.readErrorsOnly((error, stackTrace) => error is http.ClientException),
  );
});

Future<Product> data(Ref ref, {required int id}) async {
  final client = ref.abortable(ref.watch(httpClient));  // before the first await
  ...
}
```

**What `fsp create` builds** (since 0.21.0). An app made by `fsp create` has one `transport`, written once in `startup()`: `WriteGuardTransport(HttpClientTransport(http.Client()))`, wrapped by `SentryTransport` and/or `OtelTransport` when those features are chosen (`OtelTransport(SentryTransport(WriteGuardTransport(...)), isReady: () => AppMain.observability.isReady)` with both). The http feature's `httpTransport` provider is overridden with that same transport, and `authTransport`'s session wraps it too, so the session is outside the telemetry and the guard is next to the network. `WriteGuardTransport` only **marks** a write; it refuses nothing. The refusal is the retrier's predicate (`TransportClient.readsOnly()`, `readErrorsOnly()`).

`ref.abortable(...)` is the outermost layer, and it is made in the `data.dart`, because the trigger belongs to the build that asks. The rest is the provider. What the order guarantees, each pinned by a test:

- **The abort reaches every send.** `RetryClient`, `TransportClient` and `SessionTransport` all keep a request's `abortTrigger` on what they send, so a page that goes away stops the retry that follows a 503 and the replay that follows a 401.
- **Every send is authorized again.** A retrier above the session calls it again, and the session signs the exact bytes of that send, so a DPoP proof, which is single-use, is new each time. (Until 0.20.0 a DPoP API forced the retrier _outside_ the session, because `SessionClient` sent again the proof it was given; there is only one order now.)
- **A 401 is renewed, and the request is sent again once**, by the session, when the request has bytes (a plain `http.Request`, a multipart request, or anything Dio finalizes). Under Dio that is every request but one whose `data` is a `Stream`. Under `RetryClient` it is not: `RetryClient` hands the bridge a **streamed copy** of every request, so a 401 is renewed (the next request works) but **returned**, not replayed; a `data.dart` that retries reloads it. Use `TransportClient` directly (or `ref.abortable(TransportClient(...))` with no `RetryClient`) when you want the replay, and keep the retrier for the cases that need it.
- **A write is never retried.** `WriteGuardTransport` marks each send's response and error; `readsOnly()` and `readErrorsOnly()` leave a write alone, so a 503 for a write is the answer. A write with an `Idempotency-Key` is not a write for this purpose and is retried. The guard and the session can be stacked in either order (`SessionTransport(WriteGuardTransport(...))` or the reverse): a write that gets a 401 is replayed once, marked `transportReplayKey`, and never sent a third time.
- **The retrier belongs to reads and to the network error.** Give `RetryClient` both predicates: it retries a 503 for every method otherwise.

For Dio the same promises are interceptors and an adapter: the session is a transport under `TransportAdapter`, so `dio_smart_retry` is above it by construction, and `WriteGuard.install(dio)` goes **last** (it runs first), after the retrier.

```dart
final dio = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
    ..httpClientAdapter = TransportAdapter(ref.watch(authTransport));
  dio.interceptors.add(RetryInterceptor(
    dio: dio,
    retryEvaluator: WriteGuard.readsOnly(DefaultRetryEvaluator(defaultRetryableStatuses).evaluate),
  ));
  WriteGuard.install(dio);
  ref.onDispose(dio.close);
  return dio;
});
```

Every retry the interceptor makes calls the adapter again, so every send is signed afresh, a 401 is replayed once, and a request is never sent without the session it was made with: when a renewal was refused, or the user signed out or in as someone else between two sends, the retry is not sent and the caller gets a `DioException` whose `error` is an `AuthRejected`. The same cannot hold for `package:http` under a `RetryClient`, for the reason in [the memo](#one-seam-for-any-client): each copy is a new logical request, so a send made as ada, then a 503, then a sign-out, makes the next attempt go out unauthenticated, or as bob after a sign-in (and likewise after an `AuthUnavailable`). A refused renewal is not retried (an `AuthRejected` is not a `ClientException`); an unavailable one is, and each attempt asks again. What stops the stale retry is the abort: with `ref.abortable(...)` outermost and a `data.dart` that watches `authUserId` (or a guarded page), a sign-out disposes the build, its trigger completes, and `RetryClient` checks `aborted` before every attempt. The session's own replay after a 401 is refused when the user signed out meanwhile.

[HTTP transport](transport.md#decorators-and-their-order) has the order of the decorators that are not clients (`SessionTransport`, `WriteGuardTransport`, the telemetry decorators), and [Authentication](auth.md#calling-your-api) has the session.

## Credentials for clients that are not an http.Client

A transfer that is not a transport (a plugin that downloads a file, a native upload, a websocket handshake) still needs the session: the headers for a request and the answer to "send it once more?". `HttpCredentials` (since 0.15.0 in `fespalier_http`; in `fespalier_transport` since 0.21.0) is that, with no client in it:

```dart
abstract interface class HttpCredentials {
  bool covers(Uri uri);
  Future<HttpAuthorization> authorize(TransportRequest request, {HttpAuthorization? previous});
  Future<bool> retry(HttpAuthorization attempt, TransportResponse response);
}
```

`fespalier_auth`'s `Authorizer` implements it, so `ref.watch(authorizer)` is one. It takes the whole request (it was a method and a URL until 0.20.0) so a scheme that signs the body can read its exact bytes, and the whole response (it was a status code and headers) so it can read why the server refused. The loop is the one `SessionTransport` runs. `retry` says yes at most twice for one request (a challenge, then a renewal), so it ends:

```dart
Future<int> send(HttpCredentials credentials, TransportRequest request, HttpTransport transport) async {
  var attempt = await credentials.authorize(request);
  while (true) {
    final response = await TransportResponse.buffered(await transport.send(request.authorized(attempt)));
    final again = await credentials.retry(attempt, response);
    if (!again || !request.replayable) return response.statusCode;
    attempt = await credentials.authorize(request, previous: attempt);
  }
}
```

- **`covers` first.** Credentials go to the origins the session lists and to nothing else; `authorize` for another origin returns empty headers.
- **Pass `previous` back** when the same request is sent again, so the replay is counted (`isReplay`) and a renewal or a proof challenge happens once per request. An attempt that another object made is an `ArgumentError`. `request.authorized(attempt)` puts the attempt's headers on the request and marks a replay with `transportReplayKey`.
- **Buffer a 401 or a 403 before you ask `retry`** (`TransportResponse.buffered`): the credentials read its body to tell a challenge from a refusal. A response that is not buffered has no body to read there.
- **A request with a body stream is sent once.** `request.replayable` is false for it, and an authenticator that needs the bytes refuses it with an `ArgumentError`.
- **In a test**, `FakeHttpCredentials(origins: [...])` (`package:fespalier_transport/testing.dart`) attaches a canned header, asks for one re-send of the statuses in `retryOn`, and records every call (`authorizeCalls`, `retryCalls`).
