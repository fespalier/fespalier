# fespalier_http

`package:http` for [fespalier](https://github.com/fespalier/fespalier) (since 0.15.0; it was
`package:fespalier_dio/http.dart` from 0.9.0 to 0.14.0): a load whose page is gone stops, a server's validation
error lands under its form field, and a write is never sent twice. fespalier itself is unchanged: no `fsp`
change, no `fespalier:` key, and the same `app.g.dart`. It starts no timer and no listener, and it has no retry
policy of its own (a backoff needs a timer).

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
      ref: v0.14.0
  fespalier_http:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_http
      ref: v0.14.0
```

<!-- x-release-please-end -->

Needs Dart 3.8 and Flutter 3.32 or newer. It depends on `http` (`^1.5.0`, for `Abortable`), which is pure Dart,
and on nothing else: an app that uses `package:http` links no Dio.

## Libraries

| Library                                      | What is in it                                                                                        |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `package:fespalier_http/fespalier_http.dart` | `ref.abortTrigger()`, `ref.abortable(client)`, `withFieldErrors()`, `WriteGuardClient`, `HttpWrites` |
| `package:fespalier_http/problem.dart`        | no client: `FieldErrorsDecoders`, `FieldNames`, `fieldErrorsOf` (the library above exports it)       |

The seam is `package:http`'s own `Client`, `BaseRequest` and `StreamedResponse`: whatever is an `http.Client`
(`IOClient`, `cupertino_http`, `RetryClient`, a `MockClient`) fits. For Dio itself, see
[`fespalier_dio`](https://github.com/fespalier/fespalier/blob/main/packages/fespalier_dio/README.md).

## Abort a load whose page is gone

```dart
// lib/app/products/$id/data.dart
Future<Product> data(Ref ref, {required int id}) async {
  final client = ref.abortable(ref.watch(httpClient)); // before the first await
  final res = await client.get(Uri.parse('https://api.example.com/products/$id'));
  return Product.fromJson(jsonDecode(res.body) as Map<String, Object?>);
}
```

The trigger completes in `ref.onDispose`, which runs when the provider is disposed **and** before it rebuilds.
`ref.abortTrigger()` is the trigger of one `AbortableRequest`.

## Server validation errors on a form

```dart
// lib/app/(account)/nickname/action.dart
Future<void> action(Ref ref, {required NicknameFields input}) async {
  await ref
      .read(httpClient)
      .put(Uri.parse('https://api.example.com/me'), body: jsonEncode({'nick_name': input.nickname}))
      .withFieldErrors(fieldName: (key) => const {'nick_name': 'nickname'}[key] ?? key);
}
```

A 400 or 422 whose body is RFC 9457 or RFC 7807 problem details, ASP.NET Core, Laravel, Rails, Spring, JSON:API,
FastAPI or Django REST framework is thrown as the `FieldErrors` a
[`fespalier_forms`](https://github.com/fespalier/fespalier/blob/main/docs/forms.md) form shows under its fields.
Anything else is returned as it was.

## Writes are never retried

```dart
final client = RetryClient(
  WriteGuardClient(http.Client()),
  when: WriteGuardClient.readsOnly(),
  whenError: WriteGuardClient.readErrorsOnly((error, stackTrace) => error is SocketException),
);
```

`WriteGuardClient` marks what a write's send answered or threw, so `RetryClient` leaves it alone. A write is any
method but `GET`, `HEAD`, `OPTIONS` and `TRACE`, unless it carries an `Idempotency-Key` header: that is
`HttpWrites.isWrite`, the one rule `fespalier_dio`'s `WriteGuard` uses too.
