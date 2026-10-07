# HTTP clients: `fespalier_dio`

Since 0.9.0. fespalier's core has **no HTTP client**; `package:fespalier_dio` (a repository dependency next to
fespalier, **same `url` and same `ref`**) is what Dio and `package:http` need to keep three promises of `data.dart` and
`action.dart`: a load whose page is gone stops, a server's validation error lands under its form field, and a write is
never sent twice. It adds no file kind, no `fespalier:` key and no `fsp` command, and an app that does not import it is
byte for byte what it was. It starts no timer and no listener, and has **no retry policy of its own** (a backoff needs a
timer).

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_dio:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_dio
      ref: <the same tag>
```

(A fragment, not a sample: pub resolves the pair only at a release tag. A mismatch fails as it does for
`fespalier_auth`: see [`auth-package.md`](../../fespalier-guards/references/auth-package.md).)

| Library                                    | For            | What is in it                                                                          |
| ------------------------------------------ | -------------- | -------------------------------------------------------------------------------------- |
| `package:fespalier_dio/fespalier_dio.dart` | Dio            | `ref.cancelToken()`, `withFieldErrors()`, `WriteGuard`, `WriteNotRetried`              |
| `package:fespalier_dio/http.dart`          | `package:http` | `ref.abortTrigger()`, `ref.abortable(client)`, `withFieldErrors()`, `WriteGuardClient` |
| `package:fespalier_dio/problem.dart`       | no client      | `FieldErrorsDecoders`, `FieldNames`, `fieldErrorsOf` (both libraries above export it)  |

An app that uses one client imports one library (`dio` and `http` are pure Dart, so the other is not linked). Importing
**both** is fine: the two `withFieldErrors()` are on different types (`Future<T>` and `Future<http.Response>`), and the
more specific one wins.

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
import 'package:fespalier_dio/http.dart';
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

/// package:http: the retry client retries a 503 for reads only, and a connection error too.
final httpClient = Provider<http.Client>((ref) {
  final client = RetryClient(
    WriteGuardClient(http.Client()), // inside the RetryClient
    when: WriteGuardClient.readsOnly(),
    whenError: WriteGuardClient.readErrorsOnly(
      (error, stackTrace) => error is http.ClientException,
    ),
  );
  ref.onDispose(client.close);
  return client;
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
import 'package:fespalier_dio/http.dart';
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
  for every request through the wrapper. `fespalier_auth`'s `SessionClient` copies an `AbortableRequest` with its
  trigger, so a replay after a 401 is aborted too.
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

A form shows the [`FieldErrors`](forms-and-optimistic.md) its action threw under the field of the same name, and
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
  and `Future<http.Response>` has one in `package:fespalier_dio/http.dart` (it returns the response when there is
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
  returns the `FieldErrors` or null, and you throw it.

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
  `WriteGuardClient.isWrite(request)` are the rule (the second has no `extra`).
- **`WriteGuard` is an interceptor that must be first.** It records the error of a write's first send, and refuses a
  second send of the same `RequestOptions`, handing the caller **the first error** (and a debug build prints the
  message below, once per request, with the method and the path only). `WriteGuard.install(dio)` puts it at index 0,
  once, however often it is called: **call it last**, after adding the other interceptors. It works with any retrier that
  sends the same `RequestOptions` (or a `copyWith` of them) again, because its state is in `extra`, which Dio never sends.
- **`WriteGuard.readsOnly(evaluator)`** answers `false` for a write **before** asking `evaluator`, so the retrier does not
  even wait out its delay. It has the shape of `dio_smart_retry`'s `RetryEvaluator`, and no dependency on it.
- **One exception: a send after a 401.** The server refused it before running it, and that is what an authentication
  refresh sends again (`fespalier_auth`'s `SessionInterceptor` marks the replay `authReplayKey`, and sends it once per
  challenge). It is allowed once per 401, also for a response the client accepted as it was (`validateStatus`). A
  write that fails a second time is refused as above.
- **A retrier placed before the guard** sees the error first and sends the write again before the guard has recorded
  anything: that send fails with a `DioException` whose `error` is **`WriteNotRetried`**. The cure is the one in its
  message: `WriteGuard.install(dio)` after every other interceptor.
- **`package:http`.** `WriteGuardClient(inner)` forwards every request unchanged and remembers, by identity, which
  responses and which thrown errors came from a write. Put it **inside** the `RetryClient`, and give the retry client both
  predicates: `when: WriteGuardClient.readsOnly()` (a 503, for reads; pass your own rule as its argument) and
  `whenError: WriteGuardClient.readErrorsOnly(yourRule)`. Without `whenError` nothing is retried on an error, which is
  `RetryClient`'s default; without `when:` a write is retried on a 503. A response that says nothing about its request and
  went through no `WriteGuardClient` is not retried.
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

`fespalier_cratestack/dio.dart` adds three things to a Dio that a **generated** CrateStack client uses, and they sit
beside this page's, not in place of them:

- `ref.cancellable(() => client.models.order.list())` is `ref.cancelToken()` for a client whose generated options carry no
  cancel token: the token travels in a **zone value** that `CrateStackCancelInterceptor` picks up. Call it before the first
  `await`, with a body that is only the client call; a provider built inside it takes this provider's token and is cancelled
  with it. Use `ref.cancelToken()` as above for a Dio you call yourself.
- `CrateStackPortalInterceptor` rejects a `text/html` response (a captive portal, a gateway) as an error that
  `DioFailures.read` classifies as offline, which Dio does not do for a `200`.
- **`WriteGuard.install(dio)` still goes last** (it is placed first), and it counts the generated RPC reads as writes,
  because they are POSTs: no retrier repeats them, which is what you want, since Riverpod's data retry is the one layer.

[`fespalier-cratestack`](../../fespalier-cratestack/SKILL.md) has the whole Dio.

## What it does not do

No retry policy of its own (a backoff needs a timer; `RetryInterceptor` and `RetryClient` are yours). No logging. No
tracing: the HTTP spans and the trace headers come from the instrumentation you add to the client (`otel_dio`,
`otel_http`, `sentry_dio`), not from this package. No `fespalier.route` request header. A `data.dart` that wants more
than the client's own timeouts sets them on the client: fespalier starts no timer to enforce one.
