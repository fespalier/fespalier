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
      ref: v0.24.1
  fespalier_http:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_http
      ref: v0.24.1
```

<!-- x-release-please-end -->

Needs Dart 3.9 and Flutter 3.35 or newer. It depends on `http` (`^1.5.0`, for `Abortable`), which is pure Dart,
and on `fespalier` and `fespalier_transport` (pure Dart): an app that uses `package:http` links no Dio.

## Libraries

| Library                                      | What is in it                                                                                                                    |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `package:fespalier_http/fespalier_http.dart` | `ref.abortTrigger()`, `ref.abortable(client)`, `withFieldErrors()`, `HttpClientTransport`, `TransportClient`                     |
| `package:fespalier_http/testing.dart`        | `FakeHttpClient` (answers from a handler, honours an abort, records requests)                                                    |

The seam is `package:http`'s own `Client`, `BaseRequest` and `StreamedResponse`: whatever is an `http.Client`
(`IOClient`, `cupertino_http`, `RetryClient`, a `MockClient`) fits. Since 0.21.0 it is also the way into
[`fespalier_transport`](https://github.com/fespalier/fespalier/blob/main/packages/fespalier_transport/README.md),
the pure-Dart `HttpTransport` interface every fespalier networking package builds on:

- `HttpClientTransport(client)` is an `HttpTransport` over an `http.Client`, so a session
  (`fespalier_auth`), a `WriteGuardTransport` and any other decorator send through `package:http`. A failure
  before the headers are in becomes a `TransportFailure`: `TransportAborted`, `TransportTimedOut`,
  `TransportUnsent` (the connection was refused, the host was not found, the network was unreachable: read from the
  text of the error, since this package also builds for the web), `TransportUntrusted` (the TLS certificate was refused:
  a `HandshakeException`, `TlsException` or `CertificateException`, off the web only) or `TransportBroken` (everything
  else).
- `TransportClient(transport)` is the other way: an `http.Client` over any transport chain, for code written for
  `package:http` (`RetryClient`, `ref.abortable(client)`, a `data.dart`).

`HttpCredentials`, `HttpWrites` and `FakeHttpCredentials` are `fespalier_transport`'s now (`WriteGuardClient` is
its `WriteGuardTransport`), and the validation decoders (`FieldErrorsDecoders`, `FieldNames`, `fieldErrorsOf`)
are `package:fespalier/problem.dart`. For Dio itself, see
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
  TransportClient(WriteGuardTransport(HttpClientTransport(http.Client()))),
  when: TransportClient.readsOnly(),
  whenError: TransportClient.readErrorsOnly((error, stackTrace) => error is http.ClientException),
);
```

`WriteGuardTransport` marks what a write's send answered or threw, and `TransportClient` carries the mark to the
`http.StreamedResponse` and the `http.ClientException` that `RetryClient` sees, so it leaves a write alone. A write
is any method but `GET`, `HEAD`, `OPTIONS` and `TRACE`, unless it carries an `Idempotency-Key` header: that is
`HttpWrites.isWrite` (in `fespalier_transport`), the one rule `fespalier_dio`'s `WriteGuard` uses too. Without a
`WriteGuardTransport` in the chain `readsOnly()` retries nothing: a response that does not say which request it
answered might be a write's.

## The wrapping order

`ref.abortable(...)` outermost, in the `data.dart`; under it a `TransportClient` over the session, then the write
guard next to the network:
`ref.abortable(TransportClient(SessionTransport(WriteGuardTransport(HttpClientTransport(client)), authorizer)))`.
`RetryClient` sends a streamed copy of every request, so a `RetryClient` above a `TransportClient` hands the session a
body stream, which it reads once and cannot replay after a 401: keep the session's own replay (a request with bytes) in
mind before putting a retrier above it.
[HTTP clients](https://github.com/fespalier/fespalier/blob/main/docs/http.md#the-wrapping-order) has the reasons and
the other order.
