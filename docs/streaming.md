# Streaming: fespalier_stream

A page that shows something a server changes (an order's status, a queue, a price) can poll it, or the server can say when it
changed. `fespalier_stream` (since 0.25.0) is the second: **server-sent events** (`text/event-stream`, the WHATWG standard) read
through your own `HttpTransport`, as a `Stream` for a `data.dart` or as a **live feed** that Riverpod holds and that reconnects on
your app's signals. A stream that says only what changed is a [`ChangeFeed`](#something-changed-changefeed), whose topics rebuild
exactly the providers an event concerns. It starts no timer, no backoff and no retry of its own: whatever waits, waits for
something your app does.

## What streams, and where

| Where                                                               | What it is                                                                                                                         | Read                                                            |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| A `data.dart` that returns a `Stream<T>`                            | An autoDispose `StreamProvider` fespalier wraps around it; its telemetry ends at once with `stream`                                | [Data](data.md#datadart-a-function-a-selector-or-a-provider)    |
| `TransportResponse.body`                                            | Every transport hands the body on as it arrives; a decorator that must read it uses `TransportResponse.buffered`                   | [HTTP transport](transport.md#streaming-bodies)                 |
| `fespalier_stream`                                                  | Server-sent events over that body: the decoder, a connection that reconnects, live feeds, telemetry, fakes                         | this page                                                       |
| An `action.dart` function that returns a `Stream<T>` (since 0.25.0) | A write whose answer comes in pieces: its state follows each item, and leaving the page stops it                                   | [A write that streams](#a-write-that-streams-streaming-actions) |
| `ChangeFeed` (since 0.25.0 here, `fespalier_frb` re-exports it)     | A stream of "what changed" (a Rust core's, a server's), held once, and topics that rebuild exactly the providers an event concerns | [Something changed](#something-changed-changefeed)              |
| `fespalier_download`'s `HttpTransfer`                               | A body streamed to a file                                                                                                          | [Downloads](downloads.md)                                       |
| A generated CrateStack client's `stream()`                          | A procedure's items over `application/cbor-seq`                                                                                    | [CrateStack](cratestack.md)                                     |

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

On the web, the transport at the bottom of the chain must stream: see [On the web](#on-the-web).

### On the web

A browser streams a response body only through `fetch`, read chunk by chunk. Two transports do it:

- **`package:http`**: `HttpClientTransport(BrowserClient())` (`fespalier_http`). `BrowserClient` reads a `fetch` body as it
  arrives.
- **Dio, with the fetch adapter** (since 0.25.0): `DioTransport(dio)` where `dio.httpClientAdapter` is
  `FetchHttpClientAdapter()` from `package:fespalier_dio/fetch.dart`, or `webStreamingAdapter()`, which is that adapter in a web
  build and Dio's default adapter everywhere else. Dio's own web adapter uses `XMLHttpRequest` with an `arraybuffer` response, so
  the whole body arrives when the server ends it, and no event shows before that.

```dart
// lib/startup.dart
import 'package:dio/dio.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_dio/fetch.dart';

final dio = Dio()..httpClientAdapter = webStreamingAdapter();
final transport = DioTransport(dio); // wrap it in the session and the other decorators as usual
```

The fetch adapter ignores Dio's `connectTimeout` and `sendTimeout` (honouring them takes a timer, and a stream outlives them:
cancel through the `CancelToken`, which `abortTrigger` already does). **Dio's `receiveTimeout` applies to a stream on every adapter
and every platform, `DioTransport` on a device included**: Dio closes a response whose body is quiet for that long and ends it with
a `receiveTimeout` error, so a feed on a Dio with a `receiveTimeout` is dropped whenever the server is quiet for that long (any
chunk, a heartbeat comment included, restarts the watch). A Dio that carries a feed leaves `BaseOptions.receiveTimeout` null (or
zero), or the feed's requests pass `Options(receiveTimeout: Duration.zero)`; `null` in `Options` falls back to the Dio's value.
The browser follows redirects (`followRedirects: false` and `maxRedirects` are not honoured), and the request body is sent in one
piece (Firefox and Safari cannot stream one). `withCredentials` sends cookies cross-origin, as on Dio's own web adapter.
[HTTP clients](http.md#streaming-on-the-web) has the details.

What CI checks (the `fetch-adapter` job, `just fetch-adapter`), over both transports: ten events written 200 ms apart arrive one
by one through `fespalier_stream`'s connection (the first within 300 ms of being written, the ten over at least 1.5 s), closing the
connection after three makes the server see the disconnect, and headers and a status come through. For the fetch adapter alone, a
cancelled body subscription, a `CancelToken` (before and after the headers) and `close(force: true)` each abort the request at the
server, a cancel while the request body is read cancels its source, a port nothing listens on is `TransportUnsent` and a request the
browser refuses to build is not, a `POST` body arrives whole, Dio's `receiveTimeout` drops a quiet stream and `Duration.zero` (or
none) lets it stream, and `withCredentials` chooses the request's credentials.

| Browser                               | dart2js   | dart2wasm |
| ------------------------------------- | --------- | --------- |
| Chromium (Playwright's build)         | checked   | checked   |
| Firefox (Playwright's build)          | checked   | checked   |
| WebKit (Playwright's build, on Linux) | checked   | checked   |
| Safari on macOS and iOS               | UNCHECKED | UNCHECKED |

The browsers are those Playwright's pinned version installs (`ci/web-routes/package-lock.json`). The job runs the connection
without fespalier's telemetry and errors (`ServerEvents` is that connection with them, and they need Flutter, which the harness
does not build). WebKit on Linux is not Safari; to run the cases in Safari on a Mac or an iPhone by hand, `just fetch-adapter-serve`
prints the address of a page for each build ([issue #316](https://github.com/fespalier/fespalier/issues/316)).

A browser opens at most **six HTTP/1.1 connections to one origin**, and every open stream holds one, so a seventh request to that
origin (a stream or an ordinary call) waits until one closes. Keep one feed per origin, with the key in each event (see
[A live feed](#a-live-feed-livefeed)), or serve the API over HTTP/2, which shares one connection.

### The simple form: a `Stream` in `data.dart`

```dart
// lib/app/orders/$id/events/data.dart
Stream<ServerEvent> data(Ref ref, {required int id}) => ref
    .watch(apiTransport)
    .serverEvents(Uri.parse('https://api.example.com/orders/$id/events'), name: 'order');
```

`transport.serverEvents(url)` is the events as a plain stream, which fespalier wraps in a `StreamProvider` like any `Stream`
from a `data.dart`. It has no signal to reconnect on, so what a live feed waits through ends it instead:

- an orderly end after at least one event opens again at once, with `Last-Event-ID`, unless the server sent a `retry:` of more than
  zero or the connection ended in an orderly way less than a second after it opened for the second time in a row: it has no
  timer to wait with, so those end the stream without an error, as does an end with no event, or a 204;
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
or a request that nobody answered (see [Liveness](#liveness)), and reopens a waiting one once the server's retry hint has passed
(its `retry:` field, at most a day, or a `Retry-After` in seconds on a 408, 429 or 5xx). The period is your backoff: there is none of the package's. `LiveWaiting.failures`
counts the tries in a row that delivered no event, for a ticker that wants to wait longer between them. Stop the timer in
`ref.onDispose`, **not** in `ref.onCancel`: the tick must run while every page that watches a feed is hidden, because closing
their connections is what it is for. The ticker lives as long as a feed does.

### Resuming: `Last-Event-ID`

A server that sends `id:` lines lets a reconnection ask for what it missed. The connection keeps the last ID itself, and sends
it as `Last-Event-ID` whenever it opens again (after an orderly end, a drop, an idle or a pause close). `LiveOpen(resumed: true)`
says the request carried one.

A feed that nothing watches is disposed, and its connection closed. Its last ID is kept in `liveResumePoints`, per feed and per
family key, and handed to `connect` as `lastEventId` the next time the feed is watched. That ID is the one of the last event the
listener was handed: events read and held while the page was hidden are asked for again. At most 64 IDs are kept
(`LiveResumePoints.capacity`), the one written longest ago dropped first, so a family with a key per order cannot grow without
bound; a dropped one only means that feed starts from the next event. A feed that is **rebuilt** (a provider
its `connect` watches changed) starts afresh and forgets its ID: the change may be another user. `connect` may ignore the
`lastEventId` it is given and pass its own (the ID of the snapshot a page loaded, say).

The last event ID belongs to the connection object and outlives each request, as the standard says: an event with no `id:` on a
reopened connection keeps the ID the request resumed from, until the server sets another or clears it with an empty `id:`.

A block with an `id:` and no `data:` dispatches no event, but it still sets the last event ID, as the standard says: the
decoder reports it as an `EventIdUpdate`, and the next reconnection sends it (the listener's `lastEventId` moves with it once
every event before it was handed over).

After an orderly end that delivered events, the connection opens again at once only when the server did not ask for a delay
(`retry:` of more than zero, kept for the connection's life as a browser does) and this is not the second orderly end in a row of
a connection that was open less than a second: the first reopens at once, the next one waits in `LiveWaiting(ended)` for a signal
or the tick (once the `retry:` has passed), so an endpoint that answers `retry: 5000`, one event and an end is asked every
tick, not in a loop. `retry:` values over a day are read as a day.

A server that sends no `id:` (CrateStack's `@@subscribe` sends none) cannot resume: every reopen starts from the next event, and
what happened in between is a gap. Treat an event as "something changed" and read the state again, which is right after a gap.

### Liveness

A connection can stay open while nothing reaches it (a NAT that dropped it, a proxy that stalled). `LiveRules.idle` closes an
open connection whose server sent nothing, no event and no comment, for that long, on the tick; it then waits and reopens on the
next one. `lastSeen` is when the last bytes came. The same limit bounds the wait for the answer: a request that got no
response headers for that long (a half-open socket, a proxy that holds them) is given up on the tick (`LiveWaiting(failed)`,
the open span ending `failed`) and tried again on the next. A feed without `idle` waits for ever for a request nobody answers.
A signal of `reconnectOn` does not restart a request that is still connecting.

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
| The server ended the body without an event, or asked for a `retry:` delay     | `LiveWaiting(ended)`           | unchanged                                      |
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
`ref.read(liveResumePoints).clear()`. It is safe in either order with the feeds that are still watched: `clear()` also tells the
feeds built before it to keep nothing when they are disposed, so a page that goes away right after the sign-out leaves no ID
behind (and a feed that watches the user is rebuilt without one anyway).

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

An `EventCodec` that skips a message reports one more instant root span, `fespalier.stream.decode`, with
`fespalier.stream.result` (`unknown` or `error`) and `fespalier.stream.skipped`, a count, at the 1st, 2nd, 4th, 8th... skip of
each kind (see [Decoding](#decoding-eventcodec)).

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

## Something changed: `ChangeFeed`

Many streams say only **what changed**: "order 42 changed", "the cart was cleared". A Rust core behind flutter_rust_bridge says
it on a `Stream`, a server on a live connection. The answers (`core.order(42)`, `GET /orders/42`) are a `data.dart`'s business;
the stream is what keeps them current. A `ChangeFeed` holds that stream **once**, a topic says which events concern a key, and a
`data.dart` **watches** the topic: the watch is the invalidation, with no listener of your own. It was `fespalier_frb`'s from
0.13.0; since 0.25.0 it is `fespalier_stream`'s, and `fespalier_frb` re-exports the same declarations, so an app that imports
`package:fespalier_frb/fespalier_frb.dart` changes nothing ([A Rust core's changes](data.md#a-rust-cores-changes-fespalier_frb)
covers what stays there: starting the core and `ChangeCodec`).

### Topics

```dart
// lib/core/changes.dart
final changes = ChangeFeed<CoreEvent>((ref) => ref.watch(coreProvider).changes(), name: 'core');

/// Rebuilds what watches it when order [id] changes, and on no other event.
final orderChanged = changes.topic<int>((event, id) => event is OrderChanged && event.id == id);

// lib/app/orders/$id/data.dart
Future<Order> data(Ref ref, {required int id}) {
  ref.watch(orderChanged(id));
  return ref.read(coreProvider).order(id);
}
```

`changes.latest` is the **one subscription**: a provider that is never auto-disposed, so it is opened by the first topic anyone
watches (the function you gave it runs once per container, because a generated stream accepts one listener: since 0.16.0 not
again after a failure either, because the provider does not retry, which would be a `Timer`) and cancelled by the container's
disposal. Ten thousand topics are still one subscription. A topic's value is a counter per key that moves **only** when a
matching event arrives after the first watch, so `data()` is rebuilt exactly then and the screen shows the usual reload (the old
value stays up, `keepDataOnError` keeps the page if the reload fails, and the rest of
[freshness](data.md#freshness-staletime-resume-and-reconnect) applies). `changes.any` is the topic of every event (it counts them,
each event of a burst included), for a provider that depends on the whole stream (a badge count).

What it does not do. It starts no timer, schedules nothing and has no `listen` of its own: `test/no_timers_test.dart` allows none
in `lib/`. A key is rebuilt only by an event that concerns it (since 0.21.0): Riverpod calls the topic's matcher for each event
through a `select`, and an event about another key costs that call and nothing else. Events that arrive before a dependent
rebuilds (a burst, or a page that was paused) can share one rebuild, but **none is lost**: the feed remembers the last 64 events of
its subscription (`changeLogCapacity`) and a topic looks at every one it missed, so a `[7, 42, 7]` burst still rebuilds the watcher
of order 42, and `changes.any` counts each event of a burst. A watcher that missed more than 64, or whose stream was opened again,
rebuilds anyway (a rebuild too many is safe, one too few is not). Two equal events one after the other are still two changes
(`Change.seq` numbers them, because Riverpod drops a state equal to the last). A stream error stays in `changes.latest` as an
`AsyncError` and rebuilds no topic. What a stream that emits thousands of events a second costs, and the budget that bounds it,
are in [A rebuild budget](#a-rebuild-budget-changebudget). A page that is hidden in a tab has its watchers paused by Riverpod;
they catch up when it comes back _(not checked on a device)_. If `open` does `ref.watch(coreProvider)` and the core is restarted,
the stream is opened again and the next event counts as a change.

**A table, when you own the subscription.** If the app already has code that receives the events (or does not want to edit its
`data.dart` files), an `InvalidationTable` is the pure form: rules from an event to the providers it makes stale, applied by a
function you pass. It holds no container and no stream:

```dart
// lib/core/changes.dart
final table = InvalidationTable<CoreEvent>([
  InvalidationRule.on<OrderChanged, CoreEvent>((e) => [orderProvider(e.id), ordersProvider]),
  InvalidationRule.on<CartCleared, CoreEvent>((_) => [cartProvider]),
]);

// lib/app/startup.dart, in ready(container): the app's own subscription, held in a provider of the container
container.listen(changes.latest, (_, next) {
  final change = next.value;
  if (change != null) table.apply(change.event, container.invalidate);
});
```

`apply` invalidates each provider once and returns how many it invalidated. The `container.listen` in the app's `ready()` is the
app's listener, not the package's; it dies with the container.

**Testing.** `package:fespalier_stream/testing.dart` (and `package:fespalier_frb/testing.dart`, which re-exports it) has
`FakeChangeSource`, a stream you feed (`emit`, `emitError`, `close`) whose `listenCount` proves the single subscription; override
the core provider, or build the feed over `fake.stream`:

```dart
final fake = FakeChangeSource<CoreEvent>(broadcast: false); // a generated stream is single-subscription
final feed = ChangeFeed<CoreEvent>((ref) => fake.stream);
// ... pump the page that watches feed.topic(...)(42)
fake.emit(const OrderChanged(42));
await tester.pump(); // the page reloads
expect(fake.listenCount, 1);
```

### Decoding: `EventCodec`

A typed stream needs none of this: flutter_rust_bridge decodes a Rust enum into Dart classes inside the `Stream` it returns, and
a core that sends a `Vec<CoreEvent>` per message is `changes().expand((batch) => batch)`. Some sources send **raw messages**
instead:

- a server's `ServerEvent`, whose `data` is JSON text;
- a core's `StreamSink<String>` or `StreamSink<Vec<u8>>` (a `Uint8List`) of JSON, CBOR, protobuf or bincode, because one schema
  also serves a Swift or Kotlin shell;
- a `ReceivePort` of plain `dart:ffi`, a socket to a sidecar, a core updated apart from the app.

`EventCodec` (since 0.25.0; `fespalier_frb`'s `ChangeCodec` since 0.18.0 is the same codec under that package's telemetry names)
is the decoder between that stream and the feed. It is a `StreamTransformer`, so it goes into `open`, or onto a connection
(`connection.transform(codec)`), and nothing else changes: the feed numbers what it decodes, and topics, `changes.any`, the 64-event
log and `InvalidationTable` see typed events.

```dart
// lib/core/changes.dart
OrderEvent eventFromJson(Map<String, Object?> json) => switch (json['type']) {
  'OrderChanged' => OrderChanged(json['id'] as int),
  'CartCleared' => const CartCleared(),
  _ => throw const UnknownChange(), // a variant a newer server or core added
};

final orderCodec = EventCodec<ServerEvent, OrderEvent>(
  (event) => eventFromJson(jsonDecode(event.data) as Map<String, Object?>),
);
```

**A bad message is skipped, not fatal.** The codec catches what your decoder throws (a `FormatException`, a failed cast, a
`RangeError`). The next message decodes as usual, `changes.latest` keeps its last change (one bad message is not a stopped
stream, so it is no `AsyncError`), and the skipped message gets no `Change.seq` and moves no topic. For a core, this is what
decoding in Dart buys: `flutter_rust_bridge` 2.13 reads its stream in an `async*` that stops at the first throw, so a message it
cannot decode, or an error the core adds, ends a typed stream _(read in its source, not run by a test here)_. An error of the
stream itself still reaches `changes.latest` as an `AsyncError`.

**Batches.** `EventCodec.batch(split, decode)` takes a message that carries several events. Each event is numbered on its own; a
batch is a burst, so a watcher rebuilds at most once for it while another watched key is not concerned, or something watches
`changes.latest`, and one that no event of the batch concerns does not rebuild. A key watched alone takes the events of a batch
one per turn and reloads once for each that concerns it, unless its topic has [a budget](#a-rebuild-budget-changebudget). A
failing item is skipped alone; a message whose items cannot be read is skipped whole; a heartbeat is a batch of none.

```dart
final batchCodec = EventCodec.batch<String, Object?, OrderEvent>(
  (raw) => jsonDecode(raw) as List<Object?>,
  (item) => eventFromJson(item as Map<String, Object?>),
);
```

**Unknown events.** Throw `UnknownChange` from the decoder: the event is skipped and counted apart from failures. If such an
event should still refresh something, return an event of your own (a `SomethingChanged()` that the topics which care accept, or
`changes.any` counts): a rebuild too many is safe.

**What is reported.**

- `onSkipped(reason, stackTrace)`, if you pass it, runs once per skip, inside the delivery: log it and return. What it throws
  becomes an `AsyncError` of `changes.latest`, and the rest of that message's events are dropped with it (a batch's items decoded
  before it, and those after it).
- `unknownCount` and `errorCount` count the skips of each codec object, across its feeds and containers. Each subscription
  decodes on its own, so a codec shared by a broadcast source that two containers watch counts one bad message twice, calls
  `onSkipped` twice and makes the span twice.
- The span `fespalier.stream.decode` ends `skipped` with `fespalier.stream.result` `unknown`, or `error` with `error`, and
  carries `fespalier.stream.skipped`, the count of that kind so far. It is a root span: a message is decoded in the zone of
  whoever first watched the feed, so the span is not made a child of whatever was running there. `fespalier_frb`'s `ChangeCodec`
  makes the same span as `fespalier.frb.decode`, with `fespalier.frb.result` and `fespalier.frb.skipped`, as since 0.18.0
  (`DecodeReport` names the span).
- It is reported at the 1st, 2nd, 4th, 8th... skip of each kind, so a thousand unknown events make ten spans, never a thousand.
- It never carries the message, the variant's name or the error's text.
- A decoded event reports nothing, and without a telemetry sink a skip costs a counter.

**Testing.** `FakeChangeSource<String>` (or `<Uint8List>`) is the raw stream. `codec.decode(raw)` is the codec without a stream
(empty when the message is skipped), and it is also how an app that owns its subscription feeds an `InvalidationTable`:
`for (final e in orderCodec.decode(raw)) table.apply(e, container.invalidate);`. A test can check a skip directly:
`final before = batchCodec.unknownCount;`, then `expect(batchCodec.decode('[{"type":"OrderArchived","id":42}]'), isEmpty);` and
`expect(batchCodec.unknownCount, before + 1);`. A top-level codec's counters never reset, so they add up across the tests of a
run: compare with a count taken before, or assert on what `decode` returns alone.

### A rebuild budget: `ChangeBudget`

Since 0.21.0. What a stream that emits thousands of events a second costs, measured in the package's tests (`flutter test`, a
debug build, so the ratios matter more than the microseconds):

- **The keys an event does not concern: a matcher call each.** A topic's key watches the feed through a `select`, so an event
  about order 7 costs the watcher of order 42 one call of its matcher, about a microsecond, and no rebuild. Before 0.21.0 every
  watched key was rebuilt by every event, and the cost grew with the square of the keys: about 40 µs per key per event with 100
  keys watched, 200 µs with 1,000.
- **Widgets: once a frame.** Flutter rebuilds a widget at most once a frame, however often what it watches changes: 5,000 events
  in a second were 60 widget builds.
- **Providers: once per event.** Riverpod runs a provider's rebuild after two zero-length timers, not at the next frame, and
  `flutter_rust_bridge` delivers each event in an event-loop turn of its own. So a `data()` that watches a key reloads once per
  event about it: 5,000 events a second about one order are 5,000 calls to the core for 60 frames _(measured with fake time in a
  widget test, not checked on a device with a real core)_.
- **A slow `data()` never settles.** One that takes 5 ms and is invalidated every millisecond starts again before it finishes:
  over a simulated second of 1,000 events, none of the 60 frames showed a loaded value, and the page kept its old one,
  refreshing, until the stream went quiet.
- **A burst that concerns every watched key comes through one event per turn.** Riverpod 3 pauses `changes.latest` while every
  provider that watches it rebuilds, and the stream holds the rest: a key watched alone takes 1,000 events of which 500 concern it
  in 500 turns and 500 reloads. While another watched key is not concerned, or something else watches `changes.latest`, the burst
  goes through in one turn and is one reload.
- **Nobody watching: the stream holds what comes.** With no topic watched, Riverpod pauses `changes.latest` too, and the stream
  keeps what the core sends in memory until a topic is watched again _(Dart's buffering of a paused stream; not checked with a
  real core)_; that topic then rebuilds only for the events that concern it, and takes them in one turn while another watched key
  is not concerned, or something watches `changes.latest`; a key watched alone takes them one per turn, and reloads once for
  each, unless its topic has a budget. Something that keeps watching `changes.latest`, such as a "live updates stopped" banner in
  the app's shell that watches `changes.latest.select((v) => v.hasError)`, keeps the subscription flowing, so nothing is held, and
  it rebuilds on no event. A feed over a live connection stops reading instead ([below](#a-feed-over-a-live-connection)).

A budget bounds the reloads: `budget: ChangeBudget(tick)` lets each key of a topic move at most once between two ticks of
`tick`, a provider **you** fire:

```dart
// lib/core/change_tick.dart
/// Fires every 100 ms while a budgeted key is watched and active: the app's timer, not the package's.
final changeTick = NotifierProvider.autoDispose<RefetchSignal, int>(ChangeTick.new);

class ChangeTick extends RefetchSignal {
  Timer? _timer;

  void _start() => _timer ??= Timer.periodic(const Duration(milliseconds: 100), (_) => fire());

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  int build() {
    _start();
    ref.onCancel(_stop); // every budgeted key is paused (a covered page, a hidden tab): no timer
    ref.onResume(_start);
    ref.onDispose(_stop);
    return 0;
  }
}

// lib/core/changes.dart
final orderChanged = changes.topic<int>(
  (event, id) => event is OrderChanged && event.id == id,
  budget: ChangeBudget(changeTick),
);
```

A key that has not moved since the last tick moves at once on the first event that concerns it, so a quiet stream is as quick as
before; the next ones are held, and the next tick moves the key once if anything was held. That move opens the next period: an
event right after a tick that released a held change is held for the tick after it, and only a tick that moved nothing lets the
next event through at once. A held change is never dropped: it waits for the next tick however long the stream then stays quiet,
so a tick that stops firing holds it until it fires again. A tick moves only the keys that hold a change. A held key does not
rebuild, so the feed is not paused for it, and a key watched alone takes a whole burst in one turn. Measured: with a 16 ms tick,
the 5,000 events a second are 61 reloads instead of 5,000; with the slow `data()`, a 16 ms tick let 40 of the 60 frames show a
loaded value, 50 ms 21 and 100 ms 11, against none.

The tick is yours because the package has no clock: a `Timer` in it would wake an idle app, and a frame callback is a listener on
the framework; `test/no_timers_test.dart` allows neither. A `RefetchSignal` (from fespalier) fires with `fire()`; auto-dispose, as
above, it is created by the first budgeted key watched and disposed with the last. Disposal is not enough to stop the timer when a
page is hidden: Riverpod pauses the watchers of a page that an opaque route covers or a tab that is not shown, and a paused watcher
still keeps its provider alive, so a timer that is only cancelled in `onDispose` keeps firing every 100 ms for a page nobody sees
_(measured with fake time: 600 fires in a minute with the only budgeted key paused)_. The recipe starts the timer in `build`,
stops it in `onCancel` (the last active watcher is gone or paused) and starts it again in `onResume`, so no budgeted key being
active means no timer. A held change of a paused key waits for the page to be shown again and for the next tick after that. One
tick serves every budgeted topic; 100 ms is ten updates a second. `changes.any` has no budget:
`changes.topic<Null>((_, _) => true, budget: ChangeBudget(changeTick))(null)` is a budgeted "anything changed", whose value counts
moves, not events.

**Testing.** Override the tick with `RefetchSignal.new`: nothing fires it but the test, so a held change moves exactly when the
test says.

```dart
final container = ProviderContainer(overrides: [changeTick.overrideWith(RefetchSignal.new)]);
// ... the first OrderChanged(42) reloads order 42 at once, the next ones wait
container.read(changeTick.notifier).fire();
await container.pump(); // order 42 reloads once
```

### A feed over a live connection

Since 0.25.0. `ChangeFeed.live` takes what a [`LiveFeed`](#a-live-feed-livefeed) takes, a function from the `Ref` and the ID to
resume from to a `LiveConnection`, and makes its events the feed's changes:

```dart
// lib/live/changes.dart
final changes = ChangeFeed<OrderEvent>.live(
  (ref, lastEventId) => ServerEvents(
    ref.watch(apiTransport),
    Uri.parse('https://api.example.com/changes'),
    lastEventId: lastEventId,
    name: 'changes',
  ).transform(orderCodec),
  rules: LiveRules(reconnectOn: [reconnectSignal, appShowSignal]),
);

final orderChanged = changes.topic<int>((event, id) => event is OrderChanged && event.id == id);
```

Topics, `any`, the 64-event log, budgets and `InvalidationTable` work as over a stream. The connection behaves as a `LiveFeed`'s
with `keepAlive`: it opens when the first topic is watched and lives as long as the container; a drop is never an error and
waits for a signal of `LiveRules.reconnectOn` or for [the tick](#reconnecting-without-a-timer-streamticker); when every topic is
paused (each page that watches one is hidden, or nothing watches any) Riverpod pauses `changes.latest` and the connection
**stops reading**, the tick closes it if it is still paused at the next one, and a topic watched or shown again opens it with
`Last-Event-ID` ([Paused pages](#paused-pages)). `connect` runs again when a provider it watches changes (the signed-in user), with
no ID, and the connection it made before is closed. A refusal ends `changes.latest` with its error, which a page that watches it
shows; topics do not move on it. Every provider passes `retry: (_, _) => null`, and the feed starts no timer.

`ChangeFeed.live` has no `status` (a `LiveFeed` has one): a banner watches `changes.latest.select((v) => v.hasError)` for a
refusal.

A CrateStack subscription is one such connection: `fespalier_cratestack`'s `crateStackEvents` (since 0.25.0) decodes its
events, and its offline sync follows a feed's `any` through `syncPushSignal` ([Subscriptions](cratestack.md#subscriptions-subscribe),
[A push from the server](offline-first.md#a-push-from-the-server)).

### Gaps

A connection that opens again **without resuming** has missed whatever the server sent meanwhile: a server that sends no `id:`
(CrateStack's `@@subscribe` sends none), or a feed that was rebuilt (which forgets its ID). So a live change feed
treats `LiveOpen(resumed: false)` on a request made after an earlier open, or after failed tries (below), as a **gap**: it starts a
new log, and **every watched key moves once, at that moment**, without waiting for an event (`changes.any` moves by one). Each `data.dart` that watches a
topic reloads, which is the only safe answer to "something may have changed". A reopen that resumed (`LiveOpen(resumed: true)`,
the request carried `Last-Event-ID`) moves nothing: the server sends what was missed, and those events move their keys as usual.
After a gap the new log numbers from 1 again (`Change.seq`).

`resumed` only says that the request **carried** an ID: the feed cannot tell that a server ignored it. A server that cannot honour
`Last-Event-ID` (it keeps no history, or its IDs restart with the process) must not send `id:` at all, or must clear the ID with an
empty `id:` line before it ends a stream; the next request then carries none, and that open is a gap.

The rule reads the statuses of the connection: a request is a `LiveConnecting`, so the `LiveOpen` that only ends a pause is not
a reopen and moves nothing. A key watched for the first time after a gap starts from there, and a key that was paused during a
gap moves once when it is shown again. The first open of the feed is no gap when the first request opens it. An open that follows
failed tries (a `LiveConnecting` with `attempt` above 1 or a `LiveWaiting` before any open: a 503, a timeout, a network error) is a
gap even if it is the first open, because the server may have sent events while the connection was failing: every watched key
moves once at that open. The same holds for a key watched after the gap: it counts from the log it first sees, even when only
`changes.latest` (a "live updates stopped" banner) stayed watched while the gap happened.

## A write that streams: streaming actions

Since 0.25.0 an `action.dart` function may return a `Stream<T>`: a write whose answer comes in pieces, such as a text a language
model writes word by word, or the progress of an import. Its state is a `StreamActionState<T>` (running with the latest item, then
done, failed or cancelled), its hook gives `call` and `cancel()`, and the page that watches it holds the run: when the page goes
away, the subscription is cancelled, and with it the request under it. The one-shot helper holds the run until the stream ends
instead. All of it is on [Actions](actions.md#streaming-actions-streamt).

The function returns whatever stream your client gives for the answer: a generated CrateStack client's `stream()`, or a body
read through your `HttpTransport` (every transport hands `TransportResponse.body` on as it arrives):

```dart
// lib/app/docs/new/action.dart
Stream<String> draft(Ref ref, {required String input}) =>
    ref.read(draftApiProvider).write(topic: input); // your client: a Stream of the text so far
```

`transport.serverEvents(url)` suits a feed rather than a write: after an orderly end with events it opens again (above), which
would ask for the answer twice.

The run is one action span (`fespalier.action.items` counts the items), and the request's own spans are its children. Like
everything on this page, it starts no timer: a stalled stream stays stalled until the user stops it or leaves the page.

## Servers and proxies

- Answer `200` with `Content-Type: text/event-stream` and `Cache-Control: no-cache`; anything else is a refusal or a rejection
  above. A `204` tells the client to stop for good.
- **Turn buffering off.** A proxy that buffers a response holds every event until the buffer fills: nginx needs
  `proxy_buffering off;` (or the response header `X-Accel-Buffering: no`), and a gzip filter must leave `text/event-stream` alone.
- **Send a comment while quiet** (`: ping` every 15 to 30 seconds) if you want clients to tell a dead connection from a quiet one
  (`LiveRules.idle`), and so that a proxy or a load balancer does not close an idle connection.
- **Send `id:`** on each event to let a reconnection resume, and read `Last-Event-ID` on a request.
- **Send `retry:`** to slow clients down: after an orderly end a feed does not reopen before it, and waits for the tick to pass it
  (a `retry:` of 0, or none, reopens at once the first time, then waits for a signal or the tick when the bodies end within a
  second in a row).
- A subscription of CrateStack 0.15.4 (`@@subscribe`) sends none of `id:`, `retry:` or comments, and its events skip the model's
  read policy: read the row again through the API you already guard ([Subscriptions](cratestack.md#subscriptions-subscribe)).

## Not built, and unchecked

Not built: the browser's `EventSource` (above), an automatic backoff or reconnect timer, request bodies that stream on the web,
WebSockets, WebTransport, GraphQL subscriptions, background streaming, `freshness` on a stream, a streaming `form()`, a dashboard
panel for streams, a scaffold in `fsp create` or `fsp new`, and a `status` on `ChangeFeed.live`.

UNCHECKED, because no CI job can show them:

- **Devices.** A stream on Android and iOS across background and foreground, Wi-Fi to mobile, airplane mode, resuming with
  `Last-Event-ID`, iOS suspending the socket, Android Doze, a carrier proxy that buffers. Whether the app's timer runs while it is
  hidden decides when a hidden page's connection closes.
- **Safari.** CI reads event streams in Playwright's Chromium, Firefox and WebKit on Linux, with dart2js and dart2wasm
  ([On the web](#on-the-web)); Safari on macOS and iOS is not WebKit on Linux. `ServerEvents` with its telemetry and errors is run
  by no browser test, only the connection under it.
- **Proxies in production**, and HTTP/2: every measurement was HTTP/1.1 on loopback.
