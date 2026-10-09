# HTTP clients: fespalier_http and fespalier_dio

Since 0.9.0, as `fespalier_dio`; the `package:http` half is `fespalier_http` since 0.15.0. Two packages help the two clients most apps use, [`package:http`](https://pub.dev/packages/http) (`fespalier_http`) and [Dio](https://pub.dev/packages/dio) (`fespalier_dio`), keep three of
fespalier's promises: **a load whose page is gone stops**, **a server's validation error lands under its [form](forms.md)
field**, and **a write is never sent twice**.

Neither package starts a timer or a listener.

Add them next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why). An app that uses `package:http` adds `fespalier_http` and links no Dio; an app that uses Dio adds `fespalier_dio`, which brings `fespalier_http` for the write rule and the problem decoders; an app that wants both adds both:

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.15.0
  fespalier_http:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_http
      ref: v0.15.0
  fespalier_dio:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_dio
      ref: v0.15.0
```

<!-- x-release-please-end -->

`fespalier_http` depends on `http` (`^1.5.0`, the first release with abortable requests) and on nothing else; `fespalier_dio` depends on `dio` (`^5.7.0`) and on `fespalier_http`. Import only the library you use:

| Library                                      | For            | What is in it                                                                                                                               |
| -------------------------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `package:fespalier_http/fespalier_http.dart` | `package:http` | `ref.abortTrigger()`, `ref.abortable(client)`, `withFieldErrors()`, `WriteGuardClient`, `HttpWrites`, `HttpCredentials`, and `problem.dart` |
| `package:fespalier_http/problem.dart`        | no client      | `FieldErrorsDecoders`, `FieldNames`, `fieldErrorsOf`: for chopper, or a client of your own (the other libraries export it)                  |
| `package:fespalier_http/testing.dart`        | tests          | `FakeHttpClient`, `FakeHttpCredentials`                                                                                                     |
| `package:fespalier_dio/fespalier_dio.dart`   | Dio            | `ref.cancelToken()`, `withFieldErrors()`, `WriteGuard`, `WriteNotRetried`, and `problem.dart`                                               |
| `package:fespalier_dio/client.dart`          | Dio            | `DioHttpClient`: your Dio as an `http.Client` (since 0.15.0)                                                                                |

**Since 0.15.0** `package:fespalier_dio/http.dart` and `package:fespalier_dio/problem.dart` are gone: change the import to `package:fespalier_http/fespalier_http.dart` and `package:fespalier_http/problem.dart` ([Upgrading](migration.md#0150)). An app that only uses Dio changes nothing.

Nothing here retries, logs or traces by itself: it has no retry policy of its own (a backoff needs a timer), and the HTTP spans and trace headers come from the instrumentation you add to the client (`otel_dio`, `sentry_dio`).

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

fespalier promises [a write is never retried](actions.md#actiondart-typed-writes): its generated provider does not use Riverpod's retry. A client's retry layer would break that from below (`dio_smart_retry` retries every method by default, and `package:http`'s `RetryClient` retries a 503 for every method). `WriteGuard` (Dio) and `WriteGuardClient` (`package:http`) keep the promise.

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
  final client = RetryClient(                            // package:http/retry.dart: reads only
    WriteGuardClient(http.Client()),                     // inside the RetryClient
    when: WriteGuardClient.readsOnly(),                  // 503, for reads
    whenError: WriteGuardClient.readErrorsOnly((error, stackTrace) => error is http.ClientException),
  );
  ref.onDispose(client.close);
  return client;
});
```

- **A write** is any method but `GET`, `HEAD`, `OPTIONS` and `TRACE`, unless it carries an `Idempotency-Key` header
  or `Options(extra: {WriteGuard.idempotent: true})` (a write you know is safe to repeat). `Options(extra:
{WriteGuard.write: true})` makes any request one. `WriteGuardClient.isWrite(request)` is the same rule, without the
  `extra`, and both call `HttpWrites.isWrite` (since 0.15.0), so the two clients cannot disagree about what a write is.
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

- **One exception: a send after a 401.** The server refused it before running it, and that is what an
  authentication refresh sends again (`fespalier_auth`'s `SessionInterceptor` marks it `authReplayKey`). It is
  allowed once per 401, for a response the client accepted as well (`validateStatus`).
- **`package:http`.** `WriteGuardClient` forwards every request unchanged and remembers, by identity, which responses
  and which errors came from a write; `readsOnly()` and `readErrorsOnly(whenError)` consult that. Put it inside the
  `RetryClient`, and give the retry client **both** predicates: `RetryClient` retries a 503 for any method otherwise.
  A response that says nothing about its request, and went through no `WriteGuardClient`, is not retried.
- **Two retry layers multiply.** fespalier already retries a failing `data.dart` ([Retries and reloads](data.md#retries-and-reloads)), and an HTTP retrier under it multiplies the attempts. Keep one: the data retry with no HTTP retrier, or an HTTP retrier for reads with `data_retry: none` (or a `ProviderScope(retry:)` that returns null).

## One seam for any client

The seam is `package:http`'s own `Client`, `BaseRequest` and `StreamedResponse` (since 0.15.0). Nothing of
fespalier's is a client of its own: whatever is an `http.Client` fits `ref.abortable(...)`, `WriteGuardClient`, a retrier, a session and anything
that takes a client (a pack download, a translation source, a Sentry or OpenTelemetry client).

| Implementation   | Where it comes from                                                              | Notes                                                                                                         |
| ---------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `IOClient`       | `package:http` (the default `http.Client()` on a device)                         | honours `abortTrigger`                                                                                        |
| `cronet_http`    | the Android HTTP stack, as an `http.Client`                                      | an `http.Client`: the same seam                                                                               |
| `cupertino_http` | the Apple URL loading system, as an `http.Client`                                | an `http.Client`. Whether an abort reaches the network is **not checked** here: test it before you rely on it |
| `DioHttpClient`  | `package:fespalier_dio/client.dart` (since 0.15.0), your Dio as an `http.Client` | everything below goes through your Dio and its interceptors, `WriteGuard` included                            |
| `FakeHttpClient` | `package:fespalier_http/testing.dart`                                            | answers from a handler, honours an abort (no timer), records the requests and counts the aborts               |

`DioHttpClient(dio)` is for an app that has a Dio (a session interceptor, a certificate pinning adapter, a base
configuration) and a package that wants an `http.Client` (`fespalier_maps`' `packHttpClient`, `TolgeeCdn`):

```dart
final httpClient = Provider<http.Client>((ref) => DioHttpClient(ref.watch(dio)));
```

The body is streamed (`ResponseType.stream`) and every status is an answer, as `package:http` clients do (a 404 is a response, an interceptor that rejects on a status still can). An `Abortable` request's `abortTrigger` cancels the Dio request (`RequestAbortedException`), any other failure is an `http.ClientException`, a request's `Range` header passes through, and `close()` does nothing: the Dio belongs to the provider that made it.

## The wrapping order

Four layers can sit between a `data.dart` and the network: the abort, a retrier, the write guard and the session. This is the order that works with every one of them, proved by `packages/fespalier_auth/test/wrapping_order_test.dart`:

```dart
final httpClient = Provider<http.Client>((ref) {
  final inner = http.Client();
  ref.onDispose(inner.close);
  return SessionClient(                       // outermost: sees the request the caller built
    ref.watch(authorizer),
    inner: RetryClient(
      WriteGuardClient(inner),                // inside the retrier, next to the network
      when: WriteGuardClient.readsOnly(),
      whenError: WriteGuardClient.readErrorsOnly((error, stackTrace) => error is http.ClientException),
    ),
  );
});

Future<Product> data(Ref ref, {required int id}) async {
  final client = ref.abortable(ref.watch(httpClient));  // before the first await
  ...
}
```

`ref.abortable(...)` is the outermost layer, and it is made in the `data.dart`, because the trigger belongs to the build that asks. The rest is the provider. What the order guarantees, each pinned by the test:

- **The abort reaches every send.** `RetryClient` and `SessionClient` both keep a request's `abortTrigger` on the copy they send, so a page that goes away stops the retry that follows a 503 and the replay that follows a 401.
- **A 401 is refreshed and the request is sent again, once**, for a read and for a write, because the session sees the request the caller built (a plain `Request`). `RetryClient` hands what is under it a **streamed copy** of every request, and a `SessionClient` sends again only a plain `Request`: put the retrier _outside_ the session and a 401 is refreshed (so the next request works) but **returned**, not replayed.
- **A write is never retried.** `WriteGuardClient` sits inside the retrier and marks each send's response and error; `readsOnly()` and `readErrorsOnly()` leave a write alone. A write with an `Idempotency-Key` is not a write for this purpose and is retried. A write that got a 401 is still sent again once by the session (the server refused it before running it), and a 503 after that ends it.
- **The retrier belongs to reads and to the network error.** Give `RetryClient` both predicates: it retries a 503 for every method otherwise.

One case reverses the choice: a DPoP proof (`fespalier_sign_keypair`) is single-use. A retrier _inside_ the session sends again the proof it was given (the same `jti`, which a server refuses), while a retrier _outside_ the session asks the authorizer for a new proof on every attempt. If your API requires DPoP, use the other order, and accept the price above:

```dart
ref.abortable(RetryClient(WriteGuardClient(SessionClient(ref.watch(authorizer), inner: inner)), ...))
```

With it a 401 comes back to the caller after the refresh (the next request works, and a `data.dart` that retries reloads it). The test pins both orders, so neither changes silently.

For Dio the same promises are interceptors and nothing to order by hand: `WriteGuard.install(dio)` goes **last** (it runs first), after the retrier and `SessionInterceptor`.

## Credentials for clients that are not an http.Client

A transfer that is not an `http.Client` (a plugin that downloads a file, a native upload, a websocket handshake) still needs the session: the headers for a request and the answer to "send it once more?". `HttpCredentials` (since 0.15.0) is that, with no `http` in it:

```dart
abstract interface class HttpCredentials {
  bool covers(Uri uri);
  Future<HttpAuthorization> authorize(String method, Uri uri, {HttpAuthorization? previous});
  Future<bool> retry(HttpAuthorization attempt, {required int statusCode, required Map<String, String> headers});
}
```

`fespalier_auth`'s `Authorizer` implements it, so `ref.watch(authorizer)` is one. The loop is the one `SessionClient` runs. `retry` says yes at most twice for one request (a proof challenge, then a refresh), so it ends:

```dart
Future<int> send(HttpCredentials credentials, String method, Uri uri) async {
  var attempt = await credentials.authorize(method, uri);
  while (true) {
    final status = await myTransfer(method, uri, headers: attempt.headers);
    final again = await credentials.retry(attempt, statusCode: status.code, headers: status.headers);
    if (!again) return status.code;
    attempt = await credentials.authorize(method, uri, previous: attempt);
  }
}
```

- **`covers` first.** Credentials go to the origins the session lists and to nothing else; `authorize` for another origin returns empty headers.
- **Pass `previous` back** when the same request is sent again, so the replay is counted (`isReplay`) and a refresh or a proof challenge happens once per request. An attempt that another object made is an `ArgumentError`.
- **Header names in `retry` are lower case**, as `http.BaseResponse.headers` has them.
- **In a test**, `FakeHttpCredentials(origins: [...])` attaches a canned header, asks for one re-send of the statuses in `retryOn`, and records every call (`authorizeCalls`, `retryCalls`).
