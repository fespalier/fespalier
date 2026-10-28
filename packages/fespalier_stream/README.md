# fespalier_stream

Server-sent events for [fespalier](https://github.com/fespalier/fespalier) (since 0.25.0): a `text/event-stream` read through
the app's own `HttpTransport`, so its session, signature and trace apply to it like to any request, and live feeds held by
Riverpod that reconnect on the app's signals and tick. **No timer, no backoff, no retry of its own**, no `package:http` and no
Dio: it sends through `fespalier_transport`, and an app picks the client.

The full guide is [docs/streaming.md](https://github.com/fespalier/fespalier/blob/main/docs/streaming.md). This page is the
short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are the
same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.24.1
  fespalier_stream:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_stream
      ref: v0.24.1
```

<!-- x-release-please-end -->

It depends on `fespalier_transport` (at the same tag, which pub resolves for you) for `HttpTransport`. List it yourself with
the same `url` and `ref`, and `fespalier_http` or `fespalier_dio` for a transport that sends (`HttpClientTransport(client)`;
on the web, `DioTransport` over Dio's default adapter buffers a whole body, so an event stream there wants
`HttpClientTransport(BrowserClient())`).

## Wire it

```dart
// lib/live.dart: one feed, held by Riverpod
final orderEvents = LiveFeed<ServerEvent>(
  (ref, lastEventId) => ServerEvents(
    ref.watch(apiTransport), // SessionTransport(HttpClientTransport(...), ...)
    Uri.parse('https://api.example.com/orders/live'),
    lastEventId: lastEventId,
    name: 'orders',
  ),
  rules: LiveRules(reconnectOn: [reconnectSignal, appShowSignal]),
);

// lib/app/orders/data.dart: a page reloads when an order changes
Future<List<Order>> data(Ref ref) {
  ref.watch(orderEvents.latest);
  return ref.read(api).orders();
}
```

- `ServerEvents` is a `LiveConnection<ServerEvent>`: a `GET` with `Accept: text/event-stream`, decoded by the WHATWG rules
  (`EventStreamDecoder`), resumed with `Last-Event-ID`. A drop is `LiveWaiting` in its status, never an error; a 204 ends it;
  a 4xx ends it with `ServerEventsRefused`, a `DataRefusal`.
- `LiveFeed` and `LiveFeedFamily` hold one in a provider: `latest` is the last event, `status` the `LiveStatus`. A
  `reconnectOn` signal reopens a waiting connection; the app's `streamTicker` closes one whose page stayed hidden for a whole
  tick, an idle one (`LiveRules.idle`, for a server that sends comments) and reopens a waiting one once the server's retry hint
  passed. Override `streamTicker` with a `StreamTicker` that fires from your timer: the package has none.
- A feed that nothing watches is disposed with its connection, and resumes from its last event ID when watched again
  (`liveResumePoints`: call `clear()` at sign-out). A feed rebuilt because its `connect` watched a provider that changed (the
  user) starts afresh.
- `transport.serverEvents(url)` is the simple form: a plain `Stream` for a `data.dart`, which ends with the error a feed would
  wait through.
- Telemetry: `fespalier.stream.open` and `fespalier.stream.close`, short root spans with constants only
  (`FespalierStreamConventions`), never a URL, an event or an error's text.
- `package:fespalier_stream/testing.dart` has `FakeEventServer` (an `HttpTransport` that serves streams the test writes to and
  honours the abort trigger), `ManualStreamTicker`, `FakeLiveConnection` and `streamTestOverrides()`.

UNCHECKED (no CI job shows them): a stream on Android and iOS across background and foreground, a network change, iOS
socket suspension, Android Doze and a carrier proxy that buffers; and `ServerEvents` in a browser (a spike measured
`HttpClientTransport(BrowserClient())` streaming chunk by chunk in Chromium, Firefox and WebKit, not this package). See
[docs/streaming.md](https://github.com/fespalier/fespalier/blob/main/docs/streaming.md#not-built-and-unchecked).
