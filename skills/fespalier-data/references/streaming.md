# `fespalier_stream`: server-sent events, live feeds and WebSockets

Since 0.25.0. A server that says when something changed, over `text/event-stream`, read through the app's own `HttpTransport`
(so `SessionTransport`, a device signature, `OtelTransport` and `SentryTransport` all apply), as a `Stream` for a `data.dart` or
as a `LiveFeed` that Riverpod holds. It changes no generated code and adds no file kind, key or command; an app that does not
depend on it pays nothing. The user documentation is [`docs/streaming.md`](../../../docs/streaming.md).

**It starts no timer, no backoff and no retry.** A drop is a status (`LiveWaiting`), never an error, and the connection waits for
something the app does: a `LiveRules.reconnectOn` signal, or a tick of `streamTicker`, which never fires by itself. Do not add a
`Timer`, a `Future.delayed` or Riverpod's default retry to "fix" a feed that does not reconnect: override `streamTicker`.

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier_stream:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_stream
      ref: <the tag of your fespalier>
```

(A fragment, not a sample: the package README has the annotated block. List `fespalier_transport` and the client package,
`fespalier_http` or `fespalier_dio`, too.)

## A feed, and the tick that drives it

```dart
// lib/live/orders.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

/// The app's one transport (`SessionTransport(HttpClientTransport(...), ...)`), overridden where the
/// container is made.
final apiTransport = Provider<HttpTransport>(
  (ref) => throw StateError('override apiTransport with the app transport'),
);

final ordersLive = Uri.parse('https://api.example.com/orders/live');

/// One connection while something watches it; a drop waits for the network, the app being shown,
/// or the tick.
final orderEvents = LiveFeed<ServerEvent>(
  (ref, lastEventId) => ServerEvents(
    ref.watch(apiTransport),
    ordersLive,
    lastEventId: lastEventId,
    name: 'orders',
  ),
  rules: LiveRules(reconnectOn: [reconnectSignal, appShowSignal]),
);
```

```dart
// lib/live/ticker.dart
import 'dart:async';

import 'package:fespalier_stream/fespalier_stream.dart';

/// Override `streamTicker` with this where the ProviderScope is built:
/// `streamTicker.overrideWith(AppStreamTicker.new)`.
final class AppStreamTicker extends StreamTicker {
  @override
  int build() {
    // Stopped on dispose, not on cancel: the tick must run while every page is hidden.
    final timer = Timer.periodic(const Duration(seconds: 15), (_) => fire());
    ref.onDispose(timer.cancel);
    return super.build();
  }
}
```

A `data.dart` uses it in the function form (`ref.watch(orderEvents.latest);` then load, so an event reloads the page's data)
or returns it in the selector form (`ProviderListenable<AsyncValue<Order>> data({required int id}) => orderLive(id);` with a
`LiveFeedFamily<Order, int>` whose connection is `ServerEvents(...).map(...)`).

## The traps

- **The tick must run while pages are hidden.** Each `fire()` sweeps every feed's connection: it closes one that was paused at the
  tick before and still is, closes an idle one or a request nobody answered (`LiveRules.idle` bounds both), and reopens a waiting one once the server's `retry:` or
  `Retry-After` has passed. Stopping the timer in `ref.onCancel` (the `ChangeBudget` recipe does, for another reason) leaves hidden
  pages holding their connections. Without an override, nothing closes a paused connection.
- **A pause is not a close.** Riverpod pauses a feed while every watcher is hidden, and also for a moment while watchers
  rebuild (keys + 1 times per event when many keys watch one feed); a pause only stops reading. Only a pause that outlasts a whole
  tick closes, and a resume reopens with `Last-Event-ID`.
- **`LiveRules.idle` needs a server that sends comments.** It closes an open connection that heard nothing, events or comments, for
  that long. CrateStack 0.15.4's `@@subscribe` sends no heartbeat, no `id:` and no `retry:`: give it no `idle`, and treat each
  reopen as a gap (read the state again).
- **Equal events.** Riverpod drops a value that is `==` the last one. `ServerEvent` does not override `==`; a type you `map` to
  should not either, or number it, when the same event can come twice.
- **Resume points.** A feed that nothing watches is disposed with its connection; its last ID (of the last event handed to the
  listener) is kept in `liveResumePoints` and given to `connect` as `lastEventId` next time. A feed rebuilt because a provider its
  `connect` watches changed starts with `null`. Make `connect` watch the signed-in user, and call
  `ref.read(liveResumePoints).clear()` at sign-out: it is safe in either order with feeds still watched (they keep nothing when
  disposed after it), and at most 64 IDs are kept, the oldest dropped.
- **After an orderly end.** A connection that delivered events reopens at once unless the server sent a `retry:` of more than zero,
  or it is the second orderly end in a row of a connection open less than a second; then it is `LiveWaiting(ended)` until a signal
  or the tick (past the `retry:`, at most a day). An `id:` block with no `data:` still moves the resume point (`EventIdUpdate`).
  The simple form has no timer, so in those cases it ends instead.
- **The simple form ends where a feed waits.** `transport.serverEvents(url)` in a `Stream` `data.dart` ends with the
  `TransportFailure`, a `TransportBroken` (a body that broke) or a `ServerEventsUnavailable` (408, 429, 5xx), and the provider's
  retry decides (Riverpod's default re-runs `data()` with a timer, even if events came after the error). It holds its connection
  while a page is hidden. A page that must stay live uses a `LiveFeed`.
- **Refusals end it.** A 4xx (after a session's renewal, for a 401) ends the feed with `ServerEventsRefused`, a `DataRefusal`:
  `error.dart` shows, never the old value. A 204 ends it without an error; a 200 that is not `text/event-stream` with
  `ServerEventsRejected`.
- **The abort trigger.** Every request carries one, completed whenever the connection gives it up; Dio does not close a connection
  whose body listener left, so never rely on cancelling the body. An error the body then ends with is the client's own, not a
  `TransportFailure`.
- **On the web, `DioTransport` over Dio's default adapter buffers the whole body**: give the Dio
  `webStreamingAdapter()` (since 0.25.0, `package:fespalier_dio/fetch.dart`, the `fetch` adapter in a web build and Dio's
  default elsewhere), or give the feed an `HttpClientTransport(BrowserClient())` under the same decorators. The fetch adapter
  ignores Dio's `connectTimeout` and `sendTimeout`, and Dio's `receiveTimeout` drops a quiet feed on every adapter (native too), so a Dio
  that carries a feed leaves it null or passes `Options(receiveTimeout: Duration.zero)`. CI reads event streams through both in Chromium, Firefox and WebKit, with dart2js and
  dart2wasm (`just fetch-adapter`); Safari on macOS and iOS is UNCHECKED (`just fetch-adapter-serve`, issue #316), and so is `ServerEvents`' telemetry in a browser.
- **Six connections per origin** over HTTP/1.1 in a browser: one feed for many keys, with the key in the event.

## WebSockets

Since 0.25.0, `package:fespalier_stream/web_socket.dart`, a library of its own: an app that does not import it does not import
`package:web_socket`. A `SocketConnection` is a `LiveConnection<SocketMessage>`, so a `LiveFeed` or `ChangeFeed.live` holds it
with the rules above. The user documentation is [WebSockets](../../../docs/streaming.md#websockets).

```dart
// lib/live/chat.dart
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:fespalier_stream/web_socket.dart';

import 'orders.dart' show apiTransport;

/// How the rest of the app sends: it reaches whichever connection the feed holds now.
final chatSocket = Provider<SocketHandle>((ref) => SocketHandle());

/// The connection is made **in the feed's builder** and lives with that build: it is single-use.
final chat = LiveFeed<SocketMessage>(
  (ref, _) {
    final connection = SocketConnection(
      const WebSocketConnector(),
      Uri.parse('wss://api.example.com/chat'),
      // A single-use ticket, POSTed for through the app's chain before every connect.
      grantor: ticketGrantor(
        ref.watch(apiTransport),
        Uri.parse('https://api.example.com/ws-ticket'),
      ),
      // Runs on every open: a server forgets subscriptions with the socket. It can send, not listen.
      onOpen: (socket) => socket.sendText('{"join":"room-1"}'),
      name: 'chat',
    );
    ref.onDispose(ref.watch(chatSocket).attach(connection));
    return connection;
  },
  rules: LiveRules(reconnectOn: [reconnectSignal, appShowSignal]),
);

/// Sends while a socket is open; a StateError otherwise (`isOpen` asks first).
void say(WidgetRef ref, String text) =>
    ref.read(chatSocket).send(SocketText(jsonEncode({'say': text})));
```

- **A connection is single-use.** Make it in the feed's builder, never in a provider of its own that outlives the feed: the feed
  closes it when that build ends, and a rebuilt feed handed the closed one cannot listen to it again (its `events` throw a
  `StateError` that says so). Send through a `SocketHandle`, which the builder `attach`es each connection to and which always
  reaches the current one; to change the connection (another room), make the builder watch what picks it.
- **A close always waits.** 1000, 1001 and 1005 (a close frame with no code) are `LiveWaiting(ended)`, 1012 to 1014
  `unavailable`, 1006 and the rest `failed`; it never reopens by itself (the tick or a `reconnectOn` signal does), and
  `lastCloseCode` says what the server sent.
- **A refused socket is retried.** A 401 or 403 at the upgrade, or a close with 1008 or the server's own code, is
  `LiveWaiting(failed)`, and each tick opens it again with a new ticket. Only the ticket endpoint's 4xx ends the connection
  (`SocketTicketRefused`): refuse there, or read `lastCloseCode` and `LiveWaiting.failures` and close the connection
  (`ref.read(chatSocket).connection?.close()`) or stop watching the feed.
- **No resume.** `lastEventId` is always null: `onOpen` subscribes again, and a live change feed reads every reopen as a gap.
- **A pause buffers.** A WebSocket has no backpressure: a hidden page's messages are held until it is shown or until the tick
  closes the socket (`closeIfPaused`). The tick period bounds the memory.
- **The credential is a grant, not a header.** An upgrade does not go through `HttpTransport`, and a browser cannot set a
  handshake header (`WebSocketConnector` refuses one there with an `ArgumentError`, which ends the connection). `ticketGrantor`
  POSTs through the chain (the session renews a 401 and sends it again; it is a write, so no retrier repeats it after an unknown
  outcome) and puts the ticket in the URL: make the server accept it once, within seconds. A 4xx is `SocketTicketRefused` (a
  `DataRefusal`: the feed ends), a 408, 429 or 5xx a `TransportStatusError` (it waits, `unavailable`). The answer is read to
  16 KiB at most, and not at all when it is not a 2xx. On Android, iOS and the desktop the handshake is `dart:io`'s own: a pin, a
  `SecurityContext` or a proxy setting of the HTTP client behind your transport does not apply to the socket.
- **Liveness is a message.** Pings are invisible to Dart and the package sends none: `LiveRules.idle` needs the server to send a
  message while quiet, or the app's ticker to send one that the server answers.
- **`send` only while open** (`LiveOpen`, or `LivePaused(connected: true)`); inside `onOpen`, send on the `SocketSender` it is
  given (`sendText`, `sendBytes`, `protocol`: the connection reads the messages, so `onOpen` cannot). To wait for a server's
  answer, read the feed's messages, not `onOpen`.

```dart
// test/chat_test.dart
import 'package:fespalier_stream/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a reopen joins the room again', () async {
    final connector = FakeSocketConnector();
    final connection = SocketConnection(
      connector,
      Uri.parse('wss://api.example.com/chat'),
      grantor: (url) async => SocketGrant(url.replace(query: 'ticket=t1')),
      onOpen: (socket) => socket.sendText('join'),
    );
    final sub = connection.events.listen((_) {});
    await pumpEventQueue();
    expect(connector.current.url.query, 'ticket=t1');
    connector.current.closeFromPeer(1001);
    await pumpEventQueue();
    expect(connection.status, isA<LiveWaiting>());
    connection.reconnect(); // what the tick or a signal does
    await pumpEventQueue();
    expect(connector.sockets, hasLength(2));
    expect(connector.current.sentTexts, ['join']);
    await sub.cancel();
  });
}
```

## Telemetry

`fespalier.stream.open` (a request's send to its answer: `fespalier.stream.result` `open`, `done`, `refused`, `rejected`,
`unavailable`, `failed` or `cancelled`, `status_code`, `resumed`) and `fespalier.stream.close` (instant, at the end of a
connection that was open: `reason` `ended`, `failed`, `idle`, `paused` or `cancelled`, and `events`), both with `kind` `sse` and
the `name` given to `ServerEvents`; a WebSocket's carry `kind` `websocket`, and its close `close_code` (the server's code, 1006
for a socket that broke, 1005 for no code). Root spans, constants only: never a URL, a header, an event, a message, a close reason or an error's
text. An
`EventCodec` that skips a message makes `fespalier.stream.decode` (`result` `unknown` or `error`, `skipped`, a count). See
`fespalier-observability`.

A server that says only what changed is a change feed over a live connection, `ChangeFeed.live` (since 0.25.0): topics that
move only for the keys an event concerns, and a gap (a reopen that cannot resume, or an open that follows failed tries) that moves every watched key once. See
[`change-feeds.md`](change-feeds.md).

## Testing

```dart
// test/live_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/live/orders.dart';

void main() {
  test('a drop waits, and the tick reopens it from the last event', () async {
    final server = FakeEventServer();
    final container = ProviderContainer(
      overrides: [
        ...streamTestOverrides(),
        apiTransport.overrideWithValue(server),
        reconnectSignal.overrideWith(RefetchSignal.new),
        appShowSignal.overrideWith(RefetchSignal.new),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(orderEvents.latest, (_, _) {});
    await pumpEventQueue();
    server.current
      ..event('shipped', id: '7')
      ..drop();
    await pumpEventQueue();
    expect(container.read(orderEvents.latest).value?.data, 'shipped');
    (container.read(streamTicker.notifier) as ManualStreamTicker).tick();
    await pumpEventQueue();
    expect(server.requests, hasLength(2));
    expect(server.current.lastEventId, '7');
    sub.close();
  });
}
```

`FakeEventServer` answers each request with a `FakeEventConnection` the test writes to (`event`, `comment`, `retry`, `end`,
`drop`), or with what `respond(status)`, `fail(error)` or `hang()` scripted; it honours the abort trigger (`aborted`,
`abortCount`) and says whether the client stopped reading (`isPaused`, after the reader settled). `FakeLiveConnection<T>` is a
connection a test drives (`emit`, `setStatus`) and that counts what a feed asked of it.
