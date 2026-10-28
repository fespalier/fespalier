# `fespalier_stream`: server-sent events and live feeds

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
  tick before and still is, closes an idle one (`LiveRules.idle`), and reopens a waiting one once the server's `retry:` or
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
  `ref.read(liveResumePoints).clear()` at sign-out for the feeds nothing watched then.
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
- **On the web, `DioTransport` over Dio's default adapter buffers the whole body**: give the feed an
  `HttpClientTransport(BrowserClient())` under the same decorators. `ServerEvents` in a browser is UNCHECKED in CI.
- **Six connections per origin** over HTTP/1.1 in a browser: one feed for many keys, with the key in the event.

## Telemetry

`fespalier.stream.open` (a request's send to its answer: `fespalier.stream.result` `open`, `done`, `refused`, `rejected`,
`unavailable`, `failed` or `cancelled`, `status_code`, `resumed`) and `fespalier.stream.close` (instant, at the end of a
connection that was open: `reason` `ended`, `failed`, `idle`, `paused` or `cancelled`, and `events`), both with `kind` `sse` and
the `name` given to `ServerEvents`. Root spans, constants only: never a URL, a header, an event or an error's text. See
`fespalier-observability`.

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
