# HTTP clients: `fespalier_http` and `fespalier_dio`

Since 0.9.0 as `fespalier_dio`; **since 0.15.0 the `package:http` half is `fespalier_http`**. fespalier's core has **no
HTTP client**; `package:fespalier_http` (for `package:http`) and `package:fespalier_dio` (for Dio), repository
dependencies next to fespalier with **the same `url` and the same `ref`**, are what the two clients need to keep three
promises of `data.dart` and `action.dart`: a load whose page is gone stops, a server's validation error lands under its
form field, and a write is never sent twice. They add no file kind, no `fespalier:` key and no `fsp` command, and an app
that does not import them is byte for byte what it was. They start no timer and no listener, and have **no retry policy
of their own** (a backoff needs a timer).

**Since 0.21.0 both sit on one seam, `fespalier_transport`** (pure Dart, brought in by either package): an `HttpTransport`
with one method, `send(TransportRequest)`, that a session, a write guard, a download, tracing and your own code decorate.
This page is the data side (cancel, field errors, the write rule); the interface, the decorators and their order, the
memo and the failures are in [`docs/transport.md`](https://github.com/fespalier/fespalier/blob/main/docs/transport.md#the-interface)
([the order](https://github.com/fespalier/fespalier/blob/main/docs/transport.md#decorators-and-their-order),
[the failures](https://github.com/fespalier/fespalier/blob/main/docs/transport.md#failures)).

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_http: # package:http (a Dio-only app can leave it out: fespalier_dio brings it)
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_http
      ref: <the same tag>
  fespalier_dio: # Dio
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_dio
      ref: <the same tag>
```

(A fragment, not a sample: pub resolves them only at a release tag. A mismatch fails as it does for
`fespalier_auth`: see [`auth-package.md`](../../fespalier-guards/references/auth-package.md).)

| Library                                                | For            | What is in it                                                                                                                                                                                                        |
| ------------------------------------------------------ | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `package:fespalier_http/fespalier_http.dart`           | `package:http` | `ref.abortTrigger()`, `ref.abortable(client)`, `withFieldErrors()`, and since 0.21.0 `HttpClientTransport` (a transport over an `http.Client`) and `TransportClient` (an `http.Client` over a transport)             |
| `package:fespalier_http/testing.dart`                  | tests          | `FakeHttpClient`                                                                                                                                                                                                     |
| `package:fespalier_dio/fespalier_dio.dart`             | Dio            | `ref.cancelToken()`, `withFieldErrors()`, `WriteGuard`, `WriteNotRetried`, and since 0.21.0 `DioTransport` (a transport over a Dio), `TransportAdapter` (a Dio adapter over a transport) and `DioErrors.toTransport` |
| `package:fespalier_transport/fespalier_transport.dart` | no client      | `HttpTransport`, `TransportRequest`, `TransportResponse`, `TransportFailure`, `HttpCredentials`, `HttpWrites`, `WriteGuardTransport` (since 0.21.0)                                                                  |
| `package:fespalier_transport/testing.dart`             | tests          | `FakeTransport`, `FakeHttpCredentials`, `fakeResponse` (since 0.21.0)                                                                                                                                                |
| `package:fespalier/problem.dart`                       | no client      | `FieldErrorsDecoders`, `FieldNames`, `fieldErrorsOf`: the validation-error decoders, in the core since 0.21.0                                                                                                        |

**On 0.20.0 and earlier** `HttpCredentials`, `HttpWrites` and `FakeHttpCredentials` were in `fespalier_http`, and
`WriteGuardClient` (an `http.Client` wrapper) was there too: they are `fespalier_transport`'s since 0.21.0, and
`WriteGuardClient` is `WriteGuardTransport`. `DioHttpClient` (your Dio as an `http.Client`, in `package:fespalier_dio/client.dart`)
is **gone, not deprecated**: send through `DioTransport`, or give a Dio a `TransportAdapter`. The decoders were
`package:fespalier_http/problem.dart` (re-exported by `fespalier_dio`); change the import to `package:fespalier/problem.dart`.
On 0.14.0 and earlier the `package:http` half was `package:fespalier_dio/http.dart` (removed in 0.15.0).
[`fespalier-migration`](../../fespalier-migration/SKILL.md) has the steps.

An app that uses one client imports one library (`dio` and `http` are pure Dart, so the other is not linked). Importing
**both** is fine: the two `withFieldErrors()` are on different types (`Future<T>` and `Future<http.Response>`), and the
more specific one wins.

## One transport seam, the order of the layers, and credentials (since 0.21.0)

Until 0.20.0 the seam was `package:http`'s `Client` (`WriteGuardClient`, `SessionClient`, and `DioHttpClient` to put a Dio
behind it), and a Dio had its own session interceptor. Since 0.21.0 it is `HttpTransport`
([`docs/transport.md`](https://github.com/fespalier/fespalier/blob/main/docs/transport.md#the-interface)): **one chain of
decorators, and both clients are ends of it**.

- **The two ends.** `HttpClientTransport(client)` sends the chain's requests through any `http.Client` (`IOClient`,
  `cronet_http`, `cupertino_http`; whether `cupertino_http` honours an abort is **not checked**, do not promise it).
  `DioTransport(dio)` sends them through the app's Dio, with its interceptors (a retrier, `WriteGuard`): the response body
  streams, every status is an answer and not an exception, and a `DioException` becomes a `TransportFailure` (`cancel` is
  `TransportAborted`, `connectionError` and `connectionTimeout` are `TransportUnsent`, `badCertificate` is
  `TransportUntrusted`, the other timeouts are `TransportTimedOut`, the rest `TransportBroken`).
- **The other direction, for code that is written against a client.** `TransportClient(transport)` is an `http.Client` over
  the chain, so `ref.abortable(...)` and `RetryClient` work on it; `TransportAdapter(transport)` is a Dio
  `HttpClientAdapter` over the chain, so the app's Dio (with `dio_smart_retry` and `WriteGuard`) is signed in by a session
  below it. A transport's `close()` is not the client's: both wrappers' `close()` do nothing.
- **The order that is proved** (`packages/fespalier_auth/test/wrapping_order_test.dart`), outside in:
  `ref.abortable(...)`, then a retrier, then the client (`TransportClient` or the Dio's `TransportAdapter`), then
  `SessionTransport(WriteGuardTransport(HttpClientTransport(client)), authorizer)`. The session is **below the retrier**
  (was above it until 0.20.0): every send a retrier makes is authorized again, so a signature is new each time. Either
  order of the guard and the session replays a write once after a 401; the guard only has to be somewhere in the chain
  for `TransportClient.readsOnly()` to retry anything. The app's `authTransport` provider is the session over the
  `AuthConfig.transport` you gave it, so the guard goes inside that value.
- **What `fsp create` builds** (since 0.21.0): one `transport` in `startup()`, `WriteGuardTransport(HttpClientTransport(http.Client()))`, wrapped by `SentryTransport` and/or `OtelTransport` when those features are chosen; the http feature's `httpTransport` is overridden with that same transport. `WriteGuardTransport` only **marks** a write; the retrier's predicate (`readsOnly()`) is what refuses to repeat it.
- **A `RetryClient` costs the 401 replay.** It sends a streamed copy of every request, which `TransportClient` hands on
  as a body stream: the session reads it once, renews on a 401 and returns that 401 (the caller's next attempt works),
  and each copy is a **new logical request** to the memo, so the session may renew once per copy. A Dio retrier does not
  cost it: `TransportAdapter` collects the body into bytes and shares one memo across the sends of one `RequestOptions`.
  Without a retrier, an `http.Request` goes through as bytes and is replayed once.
- **`HttpCredentials`** (in `fespalier_transport`) is the session for a transfer that is not a transport: `covers(uri)`,
  `authorize(request, {previous})` returning an `HttpAuthorization` (its `headers` and `isReplay`), and
  `retry(attempt, response)`; the caller sends at most three times. `fespalier_auth`'s `Authorizer` implements it;
  `FakeTransport` and `FakeHttpCredentials` (`package:fespalier_transport/testing.dart`) and `FakeHttpClient` are the test
  doubles.

The samples below share one tiny API. `dio` is the app's Dio, with a retry interceptor for reads and the guard for
writes, and `httpClient` is the same policy for `package:http`.

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
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';

class Product {
  const Product(this.id, this.name);

  factory Product.fromJson(Map<String, Object?> json) =>
      Product(json['id']! as int, json['name']! as String);

  final int id;
  final String name;
}

class Profile {
  const Profile(this.nickname);

  factory Profile.fromJson(Map<String, Object?> json) =>
      Profile(json['nickname']! as String);

  final String nickname;
}

class Stock {
  const Stock(this.count);

  final int count;
}

/// Dio, with the retrier for reads and the guard for writes. A test overrides it.
final dio = Provider<Dio>((ref) {
  final client = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
  client.interceptors.add(
    RetryInterceptor(
      dio: client,
      // A write is never retried: the evaluator is not even asked about one.
      retryEvaluator: WriteGuard.readsOnly(
        DefaultRetryEvaluator(defaultRetryableStatuses).evaluate,
      ),
    ),
  );
  WriteGuard.install(client); // the last call: it goes first
  ref.onDispose(client.close);
  return client;
});

/// package:http: the retry client retries a 503 for reads only, and a connection error too. A real app puts a
/// SessionTransport between the guard and the client.
final httpClient = Provider<http.Client>((ref) {
  final network = http.Client();
  ref.onDispose(network.close); // TransportClient.close does nothing
  return RetryClient(
    TransportClient(
      WriteGuardTransport(HttpClientTransport(network)), // next to the network
    ),
    when: TransportClient.readsOnly(),
    whenError: TransportClient.readErrorsOnly(
      (error, stackTrace) => error is http.ClientException,
    ),
  );
});
```

## Cancelling a load whose page is gone

A `data.dart` runs again when its provider is rebuilt (an invalidation, a changed key) and is dropped when its page
is left. The old build's result is thrown away either way, but its request goes on to the end.
`ref.cancelToken()` (Dio), and `ref.abortTrigger()` or `ref.abortable(client)` (`package:http`), tie a request to the
build that made it: they fire in `ref.onDispose`, which runs when the provider is disposed **and** before it rebuilds.

```dart
// lib/app/products/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:my_app/api.dart';

Future<Product> data(Ref ref, {required int id}) async {
  final cancel = ref.cancelToken(); // before the first await
  final res = await ref
      .watch(dio)
      .get<Map<String, Object?>>('/products/$id', cancelToken: cancel);
  return Product.fromJson(res.data!);
}
```

```dart
// lib/app/products/$id/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/api.dart';

class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) => Center(child: Text(product.name));
}
```

```dart
// lib/app/stock/data.dart
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:my_app/api.dart';

/// package:http: every request of this build goes through one aborting client.
Future<Stock> data(Ref ref) async {
  final client = ref.abortable(ref.watch(httpClient)); // before the first await
  final res = await client.get(Uri.https('api.example.com', '/stock'));
  final json = jsonDecode(res.body) as Map<String, Object?>;
  return Stock(json['count']! as int);
}
```

```dart
// lib/app/stock/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/api.dart';

class StockPage extends StatelessWidget {
  const StockPage({super.key, required this.stock});

  final Stock stock;

  @override
  Widget build(BuildContext context) => Center(child: Text('${stock.count} left'));
}
```

- **Ask before the first `await`.** After the provider is gone (a stale `ref`: the build was replaced, or the
  provider was disposed), `onDispose` would throw, so `cancelToken()` returns a token that is **already cancelled** and
  `abortTrigger()` a future that has **already completed**: the request fails at once instead of running for a page
  nobody sees. A token made late in a long `data()` is the usual reason a request is not cancelled: it was asked for
  after the build was replaced.
- **One token serves every request of the build.** A request that a retrier or an authentication refresh sends again
  keeps it, because it sends the same options. `ref.abortable(client)` is the same for `package:http`: one trigger
  for every request through the wrapper. `TransportClient` passes the `Abortable` trigger on as the transport request's
  `abortTrigger`, so a session's replay after a 401 is aborted too. A Dio request carries its `CancelToken` the same way
  through `TransportAdapter`.
- **What the request fails with.** Dio: a `DioException` of type `cancel` whose `error` is `fespalier_dio: the provider
that started this request was disposed`. `package:http`: `RequestAbortedException` (``Request aborted by
`abortTrigger` ``). It fails **after** its provider is gone. With telemetry on, the data span has already ended as
  `disposed`, so it is never an error in Sentry or OpenTelemetry, and Riverpod ignores the old build's result. Seeing
  `DioException [request cancelled]` in a log is this working (`fespalier-troubleshooting` says so).
- **`ref.abortable(client)`** sends each request as its `Abortable` twin: a `Request` as an `AbortableRequest`, a
  `MultipartRequest` as an `AbortableMultipartRequest`, a `StreamedRequest` as an `AbortableStreamedRequest` (what the
  caller writes to the original's sink is piped through), with the headers, the body and the redirect settings. A request
  that has a trigger of its own is aborted by whichever fires first. **Closing the wrapper does not close your
  client.** Whether the abort reaches the network is the client's business: `package:http`'s own clients and
  `RetryClient` honour the trigger, a `MockClient` leaves it to its handler.
- It starts **no timer**: the cancellation runs inside `dispose`, which is synchronous.

## Server validation errors on forms

A form (`fespalier_forms`, [`forms.md`](forms.md)) shows the [`FieldErrors`](optimistic.md) its action threw under the field of the same name, and
`form.error` shows `FieldErrors.message` and the messages of keys that are no field. `withFieldErrors()` on the
action's own `Future` turns a validation answer into that exception. The keys must be the **record's field names**:
`fieldName` renames the server's.

```dart
// lib/app/nickname/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:my_app/api.dart';

Future<Profile> data(Ref ref) async {
  final cancel = ref.cancelToken();
  final res = await ref
      .watch(dio)
      .get<Map<String, Object?>>('/me', cancelToken: cancel);
  return Profile.fromJson(res.data!);
}
```

```dart
// lib/app/nickname/action.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:my_app/api.dart';

typedef NicknameFields = ({String nickname});

NicknameFields form(Profile profile) => (nickname: profile.nickname);

Future<Profile> action(Ref ref, {required NicknameFields input}) async {
  final res = await ref
      .read(dio)
      .put<Map<String, Object?>>('/me', data: {'nick_name': input.nickname})
      // 422 {"errors": {"nick_name": ["That nickname is taken"]}} lands under `nickname`.
      .withFieldErrors(
        fieldName: (key) => const {'nick_name': 'nickname'}[key] ?? key,
      );
  return Profile.fromJson(res.data!);
}
```

```dart
// lib/app/nickname/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/api.dart';
import 'package:my_app/app.g.dart';

class NicknamePage extends HookConsumerWidget {
  const NicknamePage({super.key, required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = NicknameRoute.useForm(ref, data: profile);
    return Scaffold(
      body: Column(
        children: [
          TextField(
            controller: form.fields.nickname.controller,
            decoration: InputDecoration(errorText: form.fields.nickname.error),
          ),
          if (form.error case final e?) Text('$e'),
          FilledButton(onPressed: form.onSubmit, child: const Text('Save')),
        ],
      ),
    );
  }
}
```

- **It is an extension on the `Future`, not an interceptor.** An interceptor can only reject with a `DioException`
  (Dio wraps whatever it rejects with), and `ActionHandle.fieldErrors` and `useForm` read an `AsyncError` whose error is
  a `FieldErrors`. Use it in an `action.dart`; a `data.dart` that gets a 422 wants its `error.dart`. It works on any
  `Future<T>` that fails with a `DioException`, so a **retrofit** client's `api.updateProfile(...).withFieldErrors()` too,
  and `Future<http.Response>` has one in `package:fespalier_http/fespalier_http.dart` (it returns the response when there is
  nothing to throw, since `package:http` does not throw for a status).
- **The rules** (`fieldErrorsOf`): only a status in `statuses` (default `{400, 422}`); the body is a JSON object
  (a decoded map, or a `String` or bytes holding one; bytes are read as UTF-8); the `decoder` names the fields and each
  gets its **first** message; `fieldName` renames the keys, and when two end up with one name the first wins. A **422**
  that names no field but has a string `detail` (problem+json) or `message` is a `FieldErrors` with only that message
  (shown as `form.error`). **A 400 never gets that message-only form**: a 400 with no field errors is usually a bug of the
  client, which should reach your error reporting. Anything else rethrows the original error, the very same object.
- **The decoders** (`FieldErrorsDecoders.standard` tries them in this order; each asks for its exact shape and returns
  null for anything else):

  | Decoder          | Shape                                                                                                                                                | Result                                                                                                                                        |
  | ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
  | `problemDetails` | RFC 9457 `errors: [{detail, pointer}]`; RFC 7807 `invalid-params: [{name, reason}]`; Spring `errors: [{field, message \| defaultMessage \| detail}]` | a pointer is a dotted path (`#/profile/color` is `profile.color`); an entry with no pointer or field is the message                           |
  | `errorsMap`      | `errors: {field: [message]}` (ASP.NET Core, Laravel, Rails)                                                                                          | a `""` or `$` key is the message, a leading `$.` is dropped; Laravel's generic `message` is not used while fields matched                     |
  | `jsonApi`        | `errors: [{source: {pointer: "/data/attributes/name"}, detail \| title}]`                                                                            | `/data/attributes/` and `/data/relationships/` are dropped; no `source` is the message                                                        |
  | `fastApi`        | `detail: [{loc: ["body", "age"], msg}]`                                                                                                              | a leading `body`, `query`, `path`, `header` or `cookie` is dropped; `loc: ["body"]` is the message                                            |
  | `flatMap`        | Django REST framework `{field: [message], non_field_errors: [message]}`                                                                              | `non_field_errors` is the message. Not when `type`, `title`, `status`, `errors` or `detail` is a key, nor a plain-string `message` or `error` |

  A `problemDetails` entry that has a `source` is JSON:API's, so `standard` leaves it to `jsonApi`.

- **`FieldNames.camelCase`** turns `first_name`, `FirstName` and `first-name` into `firstName`, each dotted segment on
  its own. It changes **case and separators only**: `nick_name` becomes `nickName`, **not** `nickname`. When the names
  differ by more than that, map them by hand, as the sample does. A key that is no field is not lost: it shows in
  `form.error`.
- **Your own shape:** a `FieldErrors? Function(Object? body)` that gets the body as a `Map<String, Object?>`, passed as
  `decoder:`. **chopper** and anything without a `Future` to extend: `fieldErrorsOf(response.statusCode, response.body)`
  returns the `FieldErrors` or null, and you throw it. `FieldErrorsDecoders`, `FieldNames` and `fieldErrorsOf` are in
  `package:fespalier/problem.dart` (neither client library exports them since 0.21.0; they were in
  `package:fespalier_http/problem.dart`, and re-exported by `fespalier_dio`, from 0.15.0 to 0.20.0).

A retrofit client is the same code over Dio, which is why it composes (retrofit's generator writes this class; the
`@PUT('/me')` annotation is the only difference, and it is not built here):

```dart
// lib/profile_api.dart
import 'package:dio/dio.dart';
import 'package:my_app/api.dart';

/// What `@RestApi() abstract class ProfileApi { @PUT('/me') Future<Profile> update(...); }` generates.
class ProfileApi {
  ProfileApi(this._dio);

  final Dio _dio;

  Future<Profile> update(String nickname) async {
    final res = await _dio.put<Map<String, Object?>>(
      '/me',
      data: {'nick_name': nickname},
    );
    return Profile.fromJson(res.data!);
  }
}
```

Its `Future<Profile>` fails with the `DioException` too, so `ref.read(profileApi).update(n).withFieldErrors()` throws the
`FieldErrors`.

## Writes are never retried, over HTTP too

fespalier promises that [a write is never retried](actions.md): the generated provider does not use Riverpod's retry. A
client's retry layer breaks that promise from below: `dio_smart_retry` retries **every method** by default (its
`DefaultRetryEvaluator`), and `package:http`'s `RetryClient` retries a **503 on every method**. The `dio` and
`httpClient` providers above are the setup that keeps it.

- **A write** is any method but `GET`, `HEAD`, `OPTIONS` and `TRACE`, **unless** it carries an `Idempotency-Key`
  header (any case) or `Options(extra: {WriteGuard.idempotent: true})`, which say it is safe to repeat.
  `Options(extra: {WriteGuard.write: true})` makes any request one. `WriteGuard.isWrite(options)` and
  `WriteGuardTransport.isWrite(request)` are the rule (the second has no `extra`); both call `HttpWrites.isWrite` (in
  `fespalier_transport` since 0.21.0), so they cannot disagree.
- **`WriteGuard` is an interceptor that must be first.** It records the error of a write's first send, and refuses a
  second send of the same `RequestOptions`, handing the caller **the first error** (and a debug build prints the
  message below, once per request, with the method and the path only). `WriteGuard.install(dio)` puts it at index 0,
  once, however often it is called: **call it last**, after adding the other interceptors. It works with any retrier that
  sends the same `RequestOptions` (or a `copyWith` of them) again, because its state is in `extra`, which Dio never sends.
- **`WriteGuard.readsOnly(evaluator)`** answers `false` for a write **before** asking `evaluator`, so the retrier does not
  even wait out its delay. It has the shape of `dio_smart_retry`'s `RetryEvaluator`, and no dependency on it.
- **One exception: a send after a 401.** The server refused it before running it, so a write that gets a 401 may be sent
  once more (an interceptor of your own that refreshes a token and replays does that). It is allowed once per 401, also
  for a response the client accepted as it was (`validateStatus`). A write that fails a second time is refused as above.
  `fespalier_auth` no longer needs it from Dio: since 0.21.0 `SessionTransport` replays below `TransportAdapter`, inside
  the chain, where `WriteGuard` does not see the second send and `WriteGuardTransport` never refuses one.
- **A retrier placed before the guard** sees the error first and sends the write again before the guard has recorded
  anything: that send fails with a `DioException` whose `error` is **`WriteNotRetried`**. The cure is the one in its
  message: `WriteGuard.install(dio)` after every other interceptor.
- **`package:http`.** `WriteGuardTransport(inner)` (was `WriteGuardClient` until 0.20.0) forwards every request unchanged
  and remembers, by identity, which responses and which thrown errors came from a write; it refuses nothing itself.
  Put it in the chain under a `TransportClient`, and give the `RetryClient` above that both predicates:
  `when: TransportClient.readsOnly()` (a 503, for reads; pass your own rule as its argument) and
  `whenError: TransportClient.readErrorsOnly(yourRule)`. Without `whenError` nothing is retried on an error, which is
  `RetryClient`'s default; without `when:` a write is retried on a 503. A response that says nothing about its request
  and went through no `WriteGuardTransport` is not retried.
- **Two retry layers multiply.** fespalier already retries a failing `data.dart` (Riverpod's retry, `data_retry: inherit`),
  so an HTTP retrier under it multiplies the attempts. **Keep one:** either the data retry and no HTTP
  retrier for reads, or an HTTP retrier for reads with `data_retry: none` in `pubspec.yaml` (or a `ProviderScope(retry:)`
  that returns null). A write has neither.

```text
fespalier_dio: PUT /me failed and was about to be sent again. A write is never retried, so its first error is returned. Give the retry interceptor WriteGuard.readsOnly(...) as its evaluator, or add an Idempotency-Key header to a write that is safe to repeat.
```

## A test

A fake `HttpClientAdapter` answers without a network, and the page under test is the real one. This test holds a request
open to show that leaving the page cancels it, checks that the 422 lands under its field and that a write is sent once.
([`fespalier-testing`](../../fespalier-testing/references/http.md) has the fake in full, the `MockClient` abort race and
the retrier with zero delays.)

```dart
// test/http_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/api.dart';
import 'package:my_app/app.g.dart';

/// A Dio adapter that answers from a function: no network, no sleeping.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.answer);

  final Future<ResponseBody> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  )
  answer;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return answer(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonAnswer(Object body, int status) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

void main() {
  testWidgets('a 422 lands under its field', (tester) async {
    final adapter = FakeAdapter((options, _) async {
      if (options.method == 'PUT') {
        return jsonAnswer({
          'errors': {
            'nick_name': ['That nickname is taken'],
          },
        }, 422);
      }
      return jsonAnswer({'nickname': 'ann'}, 200);
    });
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/nickname'),
      overrides: [dio.overrideWithValue(Dio()..httpClientAdapter = adapter)],
    );

    await tester.enterText(find.byType(TextField), 'admin');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('That nickname is taken'), findsOneWidget);
    expect(adapter.requests.map((r) => r.method), ['GET', 'PUT']);
  });

  testWidgets('leaving the page cancels the request', (tester) async {
    var cancelled = false;
    final adapter = FakeAdapter((options, cancelFuture) {
      unawaited(cancelFuture?.then((_) => cancelled = true));
      return Completer<ResponseBody>().future; // never answers
    });
    final router = AppRoutes.router(initialLocation: '/products/1');
    await pumpRouter(
      tester,
      router,
      overrides: [dio.overrideWithValue(Dio()..httpClientAdapter = adapter)],
      settle: false,
    );
    // Dio starts its chain with Timer.run, which only a pump with a duration runs.
    await tester.pump(Duration.zero);
    expect(adapter.requests, hasLength(1));
    expect(cancelled, isFalse);

    router.go('/');
    await tester.pumpAndSettle();

    expect(cancelled, isTrue);
    expect(find.text('Home'), findsOneWidget);
  });

  test('a write that gets a 503 is sent once', () async {
    final adapter = FakeAdapter((options, _) async => jsonAnswer({}, 503));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final client = container.read(dio)..httpClientAdapter = adapter;

    await expectLater(
      client.post<Object?>('/orders'),
      throwsA(
        isA<DioException>().having((e) => e.response?.statusCode, 'status', 503),
      ),
    );
    expect(adapter.requests, hasLength(1));
  });
}
```

## With `fespalier_cratestack` (since 0.10.0)

Three things belong to a **generated** CrateStack client's Dio, and they sit beside this page's, not in place of them.
**Until 0.20.0** they came from `fespalier_cratestack/dio.dart` as two interceptors and a reader
(`CrateStackCancelInterceptor`, `CrateStackPortalInterceptor`, `DioFailures`); that library is gone, and they are
transport pieces in `fespalier_cratestack.dart` since 0.21.0:

- `ref.cancellable(() => client.models.order.list())` is `ref.cancelToken()` for a client whose generated options carry no
  cancel token: the abort trigger travels in a **zone value** (`TransportZone`) that the Dio's `TransportAdapter` merges
  into the request's trigger. Call it before the first `await`, with a body that is only the client call; a provider built
  inside it takes this provider's trigger and is cancelled with it. Use `ref.cancelToken()` as above for a Dio you call
  yourself.
- `PortalTransport` throws a `TransportPortal` for a `text/html` response (a captive portal, a gateway), which
  `TransportFailures.read` classifies as offline, which Dio does not do for a `200`.
- **`WriteGuard.install(dio)` still goes last** (it is placed first), and it counts the generated RPC reads as writes,
  because they are POSTs: no retrier repeats them, which is what you want, since Riverpod's data retry is the one layer.

[`fespalier-cratestack`](../../fespalier-cratestack/SKILL.md) has the whole chain.

## Streaming on the web (since 0.25.0)

Dio's own web adapter reads a response with `XMLHttpRequest` into one buffer, so `ResponseType.stream` (what `DioTransport`
asks for) gets the whole body when the server ends it: an event stream shows nothing until it closes.
`package:fespalier_dio/fetch.dart` is the fix, and `package:http` needs none (`BrowserClient` already reads `fetch` chunk by
chunk):

```dart
// lib/api.dart
import 'package:dio/dio.dart';
import 'package:fespalier_dio/fetch.dart';

// The fetch adapter in a web build, Dio's default adapter everywhere else.
Dio makeDio() => Dio(BaseOptions(baseUrl: 'https://api.example.com'))..httpClientAdapter = webStreamingAdapter();
```

- **Cancelling aborts the `fetch`:** a `CancelToken` (before or after the headers; `DioTransport` cancels one when its
  `abortTrigger` completes), Dio closing the response, a cancelled body subscription, `close(force: true)` of a running request
  (a plain `close()` forgets the open requests, so a `close(force: true)` after it aborts nothing). A cancel while the request
  body is still being read stops reading it. An abort is `DioExceptionType.cancel`.
- **Other failures:** a `fetch` that fails before the headers is `connectionError` (`TransportUnsent` through `DioTransport`); a
  request the browser refuses to build (a `GET` with a body, a URL with a user name, a forbidden method, a header value it
  rejects) is `unknown` (`TransportBroken`), never `connectionError`, so a feed does not reconnect for ever on it; a failure in the
  body, after the headers, is a `DioException` in the body stream, not a `TransportUnsent`.
- **Timeouts:** the adapter ignores `connectTimeout` and `sendTimeout` (a timer would be needed). `receiveTimeout` is **Dio's,
  on every adapter and platform** (`DioTransport` on a device too): Dio closes a body that is quiet for that long and ends it with
  a `receiveTimeout` error, which `DioTransport` hands on in the body stream as it is (the response was already returned). A Dio that carries an event stream leaves
  `BaseOptions.receiveTimeout` null (or `Duration.zero`), or the stream's request passes `Options(receiveTimeout: Duration.zero)`
  (`null` in `Options` falls back to the Dio's; only zero or less turns the watch off). Any chunk, a heartbeat comment included,
  restarts the watch. Cancel through the `CancelToken` rather than a timeout.
- **The browser follows redirects** (`followRedirects: false` and `maxRedirects` are ignored, `redirects` is empty), and the
  request body is sent in one piece (Firefox and Safari cannot stream one).
- **`withCredentials`** (`FetchHttpClientAdapter(withCredentials: true)`, or `Options.extra['withCredentials']` for one request)
  sends cookies to another origin, as on Dio's own web adapter.
- **dart2wasm needs `dio_web_adapter` 2.0.0 or newer** (Dio imports it in every web build; 1.x uses `dart:html`): a fresh
  resolution picks 2.x, an app held at its lowest versions lists `dio_web_adapter: ">=2.0.0 <3.0.0"`.
- **Outside a browser** `FetchHttpClientAdapter` exists but its `fetch` throws `UnsupportedError`: shared code uses
  `webStreamingAdapter()`. The library imports neither Flutter nor fespalier.
- CI (`just fetch-adapter`) runs it and `BrowserClient` in Chromium, Firefox and WebKit, with dart2js and dart2wasm. Safari on
  macOS and iOS is **unchecked**: do not claim it (`just fetch-adapter-serve` and issue #316 are how a tester checks it).

## What it does not do

No retry policy of its own (a backoff needs a timer; `RetryInterceptor` and `RetryClient` are yours). No logging. No
tracing of its own: since 0.21.0 the HTTP spans and the trace headers are two decorators of the transport chain,
`OtelTransport(inner, propagateTo: ...)` (`fespalier_otel`) and `SentryTransport(inner)` (`fespalier_sentry`), which
[`fespalier-observability`](../../fespalier-observability/SKILL.md) covers; before 0.21.0 they came from the
instrumentation you added to the client (`otel_dio`, `otel_http`, `sentry_dio`). No `fespalier.route` request header. A `data.dart` that wants more
than the client's own timeouts sets them on the client: fespalier starts no timer to enforce one.
