# fespalier_dio

Dio and `package:http` for [fespalier](https://github.com/fespalier/fespalier) (since 0.9.0): a load whose page is
gone stops, a server's validation error lands under its form field, and a write is never sent twice. fespalier
itself is unchanged: no `fsp` change, no `fespalier:` key, and the same `app.g.dart`. It starts no timer and no
listener, and it has no retry policy of its own (a backoff needs a timer).

The main README documents it in context:
[HTTP clients](https://github.com/fespalier/fespalier#http-clients-fespalier_dio). This page is the short version.

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
      ref: v0.8.1
  fespalier_dio:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_dio
      ref: v0.8.1
```

<!-- x-release-please-end -->

Needs Dart 3.8 and Flutter 3.32 or newer. It depends on `dio` (`^5.4.0`) and `http` (`^1.5.0`), both pure Dart.

## Three libraries

| Library                                    | For            | What is in it                                                                          |
| ------------------------------------------ | -------------- | -------------------------------------------------------------------------------------- |
| `package:fespalier_dio/fespalier_dio.dart` | Dio            | `ref.cancelToken()`, `withFieldErrors()`, `WriteGuard`, `WriteNotRetried`              |
| `package:fespalier_dio/http.dart`          | `package:http` | `ref.abortTrigger()`, `ref.abortable(client)`, `withFieldErrors()`, `WriteGuardClient` |
| `package:fespalier_dio/problem.dart`       | no client      | `FieldErrorsDecoders`, `FieldNames`, `fieldErrorsOf` (both libraries above export it)  |

An app that uses one client imports one library, and links nothing of the other client.

## Cancel a load whose page is gone

```dart
// lib/app/products/$id/data.dart
Future<Product> data(Ref ref, {required int id}) async {
  final cancel = ref.cancelToken(); // before the first await
  final res = await ref.watch(dio).get<Map<String, Object?>>('/products/$id', cancelToken: cancel);
  return Product.fromJson(res.data!);
}
```

The token is cancelled in `ref.onDispose`, which runs when the provider is disposed **and** before it rebuilds. For
`package:http`, `ref.abortable(client)` wraps a client so that every request through it is aborted the same way
(`ref.abortTrigger()` is the trigger of one `AbortableRequest`).

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
FastAPI or Django REST framework is thrown as the `FieldErrors` a form shows under its fields. Anything else is
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
authentication refresh sends again. For `package:http`:
`RetryClient(WriteGuardClient(inner), when: WriteGuardClient.readsOnly(), whenError: WriteGuardClient.readErrorsOnly(...))`.
