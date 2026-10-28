# Streaming: fespalier_stream

A page that shows something a server changes (an order's status, a queue, a price) can poll it, or the server can say when it
changed. `fespalier_stream` (since 0.25.0) is the second: **server-sent events** (`text/event-stream`, the WHATWG standard) read
through your own `HttpTransport`, as a `Stream` for a `data.dart` or as a **live feed** that Riverpod holds and that reconnects on
your app's signals. It starts no timer, no backoff and no retry of its own: whatever waits, waits for something your app does.

## What streams, and where

| Where                                      | What it is                                                                                                         | Read                                                                |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------- |
| A `data.dart` that returns a `Stream<T>`   | An autoDispose `StreamProvider` fespalier wraps around it; its telemetry ends at once with `stream`                | [Data](data.md#datadart-a-function-a-selector-or-a-provider)        |
| `TransportResponse.body`                   | Every transport hands the body on as it arrives; a decorator that must read it uses `TransportResponse.buffered`   | [HTTP transport](transport.md#streaming-bodies)                     |
| `fespalier_stream`                         | Server-sent events over that body: the decoder, a connection that reconnects, live feeds, telemetry, fakes         | this page                                                           |
| `fespalier_frb`'s `ChangeFeed`             | A Rust core's stream of "what changed", held once, and topics that rebuild exactly the providers an event concerns | [A Rust core's changes](data.md#a-rust-cores-changes-fespalier_frb) |
| `fespalier_download`'s `HttpTransfer`      | A body streamed to a file                                                                                          | [Downloads](downloads.md)                                           |
| A generated CrateStack client's `stream()` | A procedure's items over `application/cbor-seq`                                                                    | [CrateStack](cratestack.md)                                         |

## Server-sent events: fespalier_stream

The browser's `EventSource` cannot carry an `Authorization` header, a DPoP proof or a device signature, and it would go around
your decorators, so `fespalier_stream` reads the stream itself: a `GET` through the same `HttpTransport` as every other request
(`SessionTransport`, `WriteGuardTransport`, `OtelTransport`, `SentryTransport` all see it), with `Accept: text/event-stream` and
`Cache-Control: no-cache`, decoded by the standard's rules (`EventStreamDecoder`: UTF-8, CR, LF and CRLF, `data:`, `event:`,
`id:`, `retry:`, comments). It depends on `fespalier` and `fespalier_transport`, and links neither `package:http` nor Dio.

### Install

Add `fespalier_stream` under `dependencies:` next to `fespalier`, with the same git `url` and the same `ref`: pub resolves the two
to one package only if they are the same repository dependency. The snippet, kept at the release's tag, is in
[`packages/fespalier_stream/README.md`](https://github.com/fespalier/fespalier/blob/main/packages/fespalier_stream/README.md).
List `fespalier_transport` too, and `fespalier_http` or `fespalier_dio` for a transport that sends ([HTTP transport](transport.md)).

**On the web, read a stream through `package:http`.** `HttpClientTransport(BrowserClient())` reads a `fetch` body chunk by chunk;
`DioTransport` over Dio's default web adapter receives the whole body when the server ends it, so no event arrives before that.
A Dio app can still send its other requests through Dio and give its feeds an `HttpClientTransport` wrapped in the same decorators.

### The simple form: a `Stream` in `data.dart`

```dart
// lib/app/orders/$id/events/data.dart
Stream<ServerEvent> data(Ref ref, {required int id}) => ref
    .watch(apiTransport)
    .serverEvents(Uri.parse('https://api.example.com/orders/$id/events'), name: 'order');
```

`transport.serverEvents(url)` is the events as a plain stream, which fespalier wraps in a `StreamProvider` like any `Stream`
from a `data.dart`. It has no signal to reconnect on, so what a live feed waits through ends it instead:

- an orderly end after at least one event opens again at once, with `Last-Event-ID`; an end with no event, or a 204, ends the
  stream without an error;
- a `TransportFailure`, a body that breaks (`TransportBroken`), or a 408, 429 or 5xx (`ServerEventsUnavailable`) ends it with that
  error, which `error.dart` shows and the provider's `retry` may act on (Riverpod's default runs `data()` again after 200 ms,
  doubling; pass `data_retry` or a provider of your own to change it);
- a 4xx ends it with `ServerEventsRefused`, and a 200 that is not an event stream with `ServerEventsRejected`.

A hidden page pauses the stream, which stops reading but holds the connection: nothing closes it while the page stays hidden. A
page that can stay hidden for long wants a live feed.

### A live feed: `LiveFeed`

```dart
// lib/live.dart
final orderEvents = LiveFeed<ServerEvent>(
  (ref, lastEventId) => ServerEvents(
    ref.watch(apiTransport),
    Uri.parse('https://api.example.com/orders/live'),
    lastEventId: lastEventId,
    name: 'orders',
  ),
  rules: LiveRules(reconnectOn: [reconnectSignal, appShowSignal]),
);

// lib/app/orders/data.dart: the list reloads when an order changes
Future<List<Order>> data(Ref ref) {
  ref.watch(orderEvents.latest);
  return ref.read(api).orders();
}
```

- **`latest`** is the last event as an `AsyncValue`: loading until the first, an error only when the connection ended with one
  (a refusal, a `connect` that threw). Watching it opens the connection. A drop is **never** an error here: the value stays,
  and the connection waits.
- **`status`** is where the connection is: `LiveConnecting(attempt)`, `LiveOpen(resumed:)`, `LivePaused(connected:)`,
  `LiveWaiting(drop, since:, failures:, retryHint:)` or `LiveDone(end)`. A banner watches it; watching it keeps the feed alive.
- **`connect`** runs when the feed is first watched, and again when a provider it watches changes; the connection it made
  before is closed (its `abortTrigger` completed). Every provider of the package passes `retry: (_, _) => null`.
- **`ServerEvents(...).map(convert)`** and `.transform(transformer)` convert the events. Riverpod does not notify a value that
  is `==` the previous one, so map to a type that does not override `==`, or number them, when the same event can come twice
  (`ServerEvent` does not override it).
- **`LiveFeedFamily<T, K>`** is a feed per key: `orderLive(42)`, and `orderLive.status(42)`. A selector `data.dart` returns it:

```dart
// lib/app/orders/$id/data.dart
ProviderListenable<AsyncValue<Order>> data({required int id}) => orderLive(id);
```

A browser opens at most six HTTP/1.1 connections to one origin, and each feed key holds one: a screen that watches many keys
wants one feed for all of them, with the key in each event (or `ChangeFeed`'s topics over it), or HTTP/2.

### Reconnecting without a timer: `streamTicker`

A connection that dropped waits (`LiveWaiting`) until something reopens it:

- **a signal** of `LiveRules.reconnectOn` changes: core's `reconnectSignal` (`fespalier_connectivity` fires it when the network
  comes back) and `appShowSignal` (the app is visible again). It reopens at once. A signal that changes while the page is hidden
  is seen when it is shown.
- **the tick**: `streamTicker`, a `StreamTicker` whose `fire()` sweeps every feed's connection. It never fires by itself. Override
  it with one that fires from your timer:

```dart
// lib/live.dart
final class AppStreamTicker extends StreamTicker {
  @override
  int build() {
    final timer = Timer.periodic(const Duration(seconds: 15), (_) => fire());
    ref.onDispose(timer.cancel);
    return super.build();
  }
}

// lib/app.dart (or wherever your ProviderScope is built)
ProviderScope(overrides: [streamTicker.overrideWith(AppStreamTicker.new)], child: ...)
```

Each tick closes a connection that stayed paused since the tick before (see [Paused pages](#paused-pages)), closes an idle one
(see [Liveness](#liveness)), and reopens a waiting one once the server's retry hint has passed (its `retry:` field, or a
`Retry-After` in seconds on a 408, 429 or 5xx). The period is your backoff: there is none of the package's. `LiveWaiting.failures`
counts the tries in a row that delivered no event, for a ticker that wants to wait longer between them. Stop the timer in
`ref.onDispose`, **not** in `ref.onCancel`: the tick must run while every page that watches a feed is hidden, because closing
their connections is what it is for. The ticker lives as long as a feed does.

### Resuming: `Last-Event-ID`

A server that sends `id:` lines lets a reconnection ask for what it missed. The connection keeps the last ID itself, and sends
it as `Last-Event-ID` whenever it opens again (after an orderly end, a drop, an idle or a pause close). `LiveOpen(resumed: true)`
says the request carried one.

A feed that nothing watches is disposed, and its connection closed. Its last ID is kept in `liveResumePoints`, per feed and per
family key, and handed to `connect` as `lastEventId` the next time the feed is watched. That ID is the one of the last event the
listener was handed: events read and held while the page was hidden are asked for again. A feed that is **rebuilt** (a provider
its `connect` watches changed) starts afresh and forgets its ID: the change may be another user. `connect` may ignore the
`lastEventId` it is given and pass its own (the ID of the snapshot a page loaded, say).

A server that sends no `id:` (CrateStack's `@@subscribe` sends none) cannot resume: every reopen starts from the next event, and
what happened in between is a gap. Treat an event as "something changed" and read the state again, which is right after a gap.

### Liveness

A connection can stay open while nothing reaches it (a NAT that dropped it, a proxy that stalled). `LiveRules.idle` closes an
open connection whose server sent nothing, no event and no comment, for that long, on the tick; it then waits and reopens on the
next one. `lastSeen` is when the last bytes came.

It only works with a server that sends a comment (`: ping`) more often than the limit while it has nothing to say. A server that
sends nothing while quiet would be closed when it is healthy: **CrateStack 0.15.4 sends no heartbeat**, so a CrateStack
subscription gets no `idle`, and its liveness is what the transport reports when the connection breaks.

### Paused pages

Riverpod pauses a provider while every widget that watches it is hidden (`TickerMode` off: a covered route, a tab offstage), and
the pause reaches the connection: it **stops reading** (the chunk it was waiting for is still read, and held), and `status` is
`LivePaused(connected: true)`. Riverpod also pauses it for a moment while the providers that watch it rebuild, many times per
event when many keys watch one feed, so a pause alone never closes anything. The tick closes a connection that was paused at
the tick before and still is (`LivePaused(connected: false)`), and showing the page opens it again with `Last-Event-ID`. Without
a ticker, a hidden page's connection stays open, unread.

### Errors and refusals

| What happened                                                                 | `status`                       | `latest`                                       |
| ----------------------------------------------------------------------------- | ------------------------------ | ---------------------------------------------- |
| No answer (`TransportFailure`), credentials not reachable, a body that breaks | `LiveWaiting(LiveDrop.failed)` | unchanged                                      |
| 408, 429, 5xx                                                                 | `LiveWaiting(unavailable)`     | unchanged                                      |
| The server ended the body without an event                                    | `LiveWaiting(ended)`           | unchanged                                      |
| 204                                                                           | `LiveDone(done)`               | unchanged, the stream ends                     |
| Another 4xx, or a decorator's `DataRefusal` (a session that ended)            | `LiveDone(refused)`            | `ServerEventsRefused` (a `DataRefusal`), or it |
| A 200 that is not `text/event-stream`, a status no event stream has           | `LiveDone(rejected)`           | `ServerEventsRejected`                         |
| An event over `maxEventBytes` (1 MiB)                                         | `LiveWaiting(failed)`          | unchanged                                      |

A refusal is never kept behind an old value: a page shows `error.dart` ([`DataRefusal`](data.md#freshness-staletime-resume-and-reconnect)). Under a
`SessionTransport`, a 401 is renewed and sent again inside the one request, and a refused renewal is the 401 the connection
sees. The session reads a 401's body (up to 64 KiB) and drains it before it sends again, which a real server's short 401 body
never makes a problem.

Every request carries an `abortTrigger` that the connection completes when it gives the request up: a cancel, a close, a pause
or idle close, a replaced connection, an answer it does not read. Cancelling a body is not enough to free the connection with
every client (Dio keeps reading a body whose listener left), and the body then ends with the client's own error, which the
connection ignores because it aborted the request itself.

### Sign-in and sign-out

Make `connect` watch who is signed in, so that signing out or in as someone else replaces the connection, with no resume point:

```dart
final orderEvents = LiveFeed<ServerEvent>((ref, lastEventId) {
  ref.watch(authSession.select((s) => s is SignedIn ? s.session.user.id : null));
  return ServerEvents(ref.watch(apiTransport), ordersLive, lastEventId: lastEventId);
});
```

At sign-out, also forget the resume points of the feeds nothing watched at the time, next to your other account data:
`ref.read(liveResumePoints).clear()`.

### Telemetry

Two short **root spans** per connection, never one that lives as long as the connection (an exporter would hold it for hours, and
a crash would lose it), whose names are this package's contract (`FespalierStreamConventions`):

| Span                     | When                                                                  | Attributes                                                                                                                                                               |
| ------------------------ | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `fespalier.stream.open`  | from a request's send to its answer                                   | `fespalier.stream.kind` (`sse`), `.name`, `.resumed`; at the end `.result` (`open`, `done`, `refused`, `rejected`, `unavailable`, `failed`, `cancelled`), `.status_code` |
| `fespalier.stream.close` | at the end of a connection that was open, starting and ending at once | `.kind`, `.name`; at the end `.reason` (`ended`, `failed`, `idle`, `paused`, `cancelled`) and `.events`, the number it delivered                                         |

`name` is the one you gave `ServerEvents` (`[a-z][a-z0-9_]*`, checked in debug). Neither span carries a URL, a query, a header,
an event's type, data or id, or an error's text. They are root spans, so they are not children of whatever the page that first
watched the feed was doing. With no sink installed, each is one null check. The `http` span of `OtelTransport` and the breadcrumb
of `SentryTransport` end when the headers arrive, so their duration is the time to the first byte, not the stream's.

### Testing

`package:fespalier_stream/testing.dart`:

- **`FakeEventServer`** is an `HttpTransport` that serves event streams: each request gets a `FakeEventConnection` the test writes
  to (`event(data, type:, id:)`, `comment()`, `retry(delay)`, `end()`, `drop()`), unless `respond(status)`, `fail(error)` or
  `hang()` scripted the answer. It honours the `abortTrigger` as a real client does (`aborted`, `abortCount`), and says whether
  the client stopped reading (`isPaused`) and what it asked for (`lastEventId`, `header`).
- **`ManualStreamTicker`** and **`streamTestOverrides()`**: `ProviderContainer(overrides: streamTestOverrides())`, then
  `(container.read(streamTicker.notifier) as ManualStreamTicker).tick()`.
- **`FakeLiveConnection<T>`**: a connection the test drives (`emit`, `setStatus`), counting what a feed asked of it.

```dart
test('a drop waits and the tick reopens it, from the last event', () async {
  final server = FakeEventServer();
  final feed = LiveFeed<ServerEvent>(
    (ref, lastEventId) => ServerEvents(server, url, lastEventId: lastEventId),
  );
  final container = ProviderContainer(overrides: streamTestOverrides());
  addTearDown(container.dispose);
  final sub = container.listen(feed.latest, (_, _) {});
  await pumpEventQueue();
  server.current
    ..event('shipped', id: '7')
    ..drop();
  await pumpEventQueue();
  (container.read(streamTicker.notifier) as ManualStreamTicker).tick();
  await pumpEventQueue();
  expect(server.current.lastEventId, '7');
  sub.close();
});
```

## Servers and proxies

- Answer `200` with `Content-Type: text/event-stream` and `Cache-Control: no-cache`; anything else is a refusal or a rejection
  above. A `204` tells the client to stop for good.
- **Turn buffering off.** A proxy that buffers a response holds every event until the buffer fills: nginx needs
  `proxy_buffering off;` (or the response header `X-Accel-Buffering: no`), and a gzip filter must leave `text/event-stream` alone.
- **Send a comment while quiet** (`: ping` every 15 to 30 seconds) if you want clients to tell a dead connection from a quiet one
  (`LiveRules.idle`), and so that a proxy or a load balancer does not close an idle connection.
- **Send `id:`** on each event to let a reconnection resume, and read `Last-Event-ID` on a request.
- **Send `retry:`** to slow clients down after a restart: a feed does not reopen before it on the tick.
- A subscription of CrateStack 0.15.4 (`@@subscribe`) sends none of `id:`, `retry:` or comments, and its events skip the model's
  read policy: read the row again through the API you already guard.

## Not built, and unchecked

Not built: the browser's `EventSource` (above), an automatic backoff or reconnect timer, request bodies that stream on the web,
WebSockets, WebTransport, GraphQL subscriptions, background streaming, `freshness` on a stream, a streaming `form()`, a dashboard
panel for streams, and a scaffold in `fsp create` or `fsp new`.

UNCHECKED, because no CI job can show them:

- **Devices.** A stream on Android and iOS across background and foreground, Wi-Fi to mobile, airplane mode, resuming with
  `Last-Event-ID`, iOS suspending the socket, Android Doze, a carrier proxy that buffers. Whether the app's timer runs while it is
  hidden decides when a hidden page's connection closes.
- **Browsers.** `ServerEvents` itself is run by no browser test. A spike read event streams chunk by chunk through
  `HttpClientTransport(BrowserClient())` in Chromium, Firefox and WebKit (on Linux, not Safari), with dart2js and dart2wasm, and saw
  Dio's default web adapter deliver a whole body at its end.
- **Proxies in production**, and HTTP/2: every measurement was HTTP/1.1 on loopback.
