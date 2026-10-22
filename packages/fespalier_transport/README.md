# fespalier_transport

The seam [fespalier](https://github.com/fespalier/fespalier)'s networking packages share (since 0.21.0): an
`HttpTransport` interface with its `TransportRequest` and `TransportResponse`, the `HttpCredentials` contract a
session implements, and `HttpWrites`, the one rule for what counts as a write. **Pure Dart, no dependencies**: an
auth package that sends through it links neither `package:http` nor Dio, and an app picks one (or its own client)
by choosing which package implements the interface.

| Package          | Implements it with                                                           |
| ---------------- | ---------------------------------------------------------------------------- |
| `fespalier_http` | `HttpClientTransport` over an `http.Client`; `TransportClient` the other way |
| `fespalier_dio`  | `DioTransport` over a `Dio`; `TransportAdapter` the other way                |

Decorators compose, because a decorator is a transport over a transport:
`SessionTransport(WriteGuardTransport(HttpClientTransport(client)), authorizer)`.

## Install

You rarely add it yourself: `fespalier_http`, `fespalier_dio` and `fespalier_auth` depend on it. Add it next to
fespalier, with the same `url` and the same `ref`, to implement a transport of your own.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier_transport:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_transport
      ref: v0.20.0
```

<!-- x-release-please-end -->

Needs Dart 3.9 and Flutter 3.35 or newer.

## Libraries

| Library                                                | What is in it                                                                                                                        |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| `package:fespalier_transport/fespalier_transport.dart` | `HttpTransport`, `TransportRequest`, `TransportResponse`, `TransportFailure`, `HttpCredentials`, `HttpWrites`, `WriteGuardTransport` |
| `package:fespalier_transport/testing.dart`             | `FakeTransport` (answers from a handler or a script, honours an abort, records requests), `FakeHttpCredentials`, `fakeResponse`      |

It starts no timer and no listener (`test/no_timers_test.dart`).
