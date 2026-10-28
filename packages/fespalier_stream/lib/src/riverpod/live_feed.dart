import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';

import '../wire/live_connection.dart';
import '../wire/live_status.dart';

part 'live_notifier.dart';
part 'ticker.dart';

/// What makes a live feed act besides its listener (since 0.25.0).
final class LiveRules {
  /// No signal and no idle limit, or the ones given.
  const LiveRules({this.reconnectOn = const [], this.idle});

  /// Signals that reconnect a waiting connection at once when they change, usually core's
  /// `reconnectSignal` (the network came back) and `appShowSignal` (the app is visible again). A
  /// change while the feed is paused (its page hidden) is seen when it resumes.
  final List<ProviderListenable<Object?>> reconnectOn;

  /// Closes an open connection whose server said nothing for this long, on the app's tick, so it
  /// waits and reconnects. Only for a server that sends a comment (`: ping`) more often than this
  /// while it has nothing to say: a server that sends nothing while quiet (CrateStack's
  /// subscriptions) would be closed when it is healthy.
  final Duration? idle;
}

/// The last event ID of each feed whose listeners went away, so that the feed resumes from it when
/// it is watched again (since 0.25.0).
///
/// A feed's provider is auto-disposed when nothing watches it, and the connection with it; the ID
/// it would resume from is kept here, per feed and per family key, and handed to `connect` on the
/// feed's next build. A feed that is **rebuilt** (a provider its `connect` watches changed: the
/// signed-in user, the transport) forgets its ID instead: the change may be another user, whose
/// position in the stream this is not. [clear] forgets them all: call it at sign-out, next to the
/// app's other account data, for the feeds that nothing watched at the time.
final class LiveResumePoints {
  LiveResumePoints._();

  final Map<Object, String> _ids = <Object, String>{};

  /// How many IDs are kept.
  int get length => _ids.length;

  /// Forgets every kept ID.
  void clear() => _ids.clear();

  String? _read(Object slot) => _ids[slot];

  void _keep(Object slot, String id) => _ids[slot] = id;

  void _forget(Object slot) => _ids.remove(slot);
}

/// The kept resume points of the container (since 0.25.0): `ref.read(liveResumePoints).clear()`
/// at sign-out.
final liveResumePoints = Provider<LiveResumePoints>(
  (ref) => LiveResumePoints._(),
  retry: (_, _) => null,
);

/// A live connection held by Riverpod (since 0.25.0): [latest] is its last event, for a page or a
/// `data.dart`, and [status] where it is.
///
/// ```dart
/// final orderEvents = LiveFeed<ServerEvent>(
///   (ref, lastEventId) => ServerEvents(
///     ref.watch(apiTransport),
///     Uri.parse('https://api.example.com/orders/live'),
///     lastEventId: lastEventId,
///     name: 'orders',
///   ),
///   rules: LiveRules(reconnectOn: [reconnectSignal, appShowSignal]),
/// );
/// ```
///
/// [connect] runs when the feed is first watched, and again when a provider it watches changes
/// (sign-in and sign-out, when it watches the user); the connection it returned before is closed.
/// `lastEventId` is where to resume from: the ID the feed kept when it was last disposed, null on a
/// rebuild (see [LiveResumePoints]). Within one connection's life, the connection resumes by
/// itself.
///
/// The feed waits on nothing of its own (no timer, no backoff, no retry: every provider here sets
/// `retry` to null): a drop is [LiveWaiting] in [status], never an error in [latest], and the
/// connection opens again when a signal of [rules] changes, or on the app's [streamTicker] once
/// the server's retry hint has passed. A page that is hidden pauses the feed, which stops reading;
/// the tick closes a connection that stayed paused, and showing the page opens it again. A
/// refusal (a 4xx, a session that ended) ends [latest] with it, which a page shows as its error.
///
/// Riverpod does not notify a new value that is `==` the old one: map events to a type that does
/// not override `==` (as `ServerEvent` does not), or number them, so a repeat still arrives.
/// [keepAlive] keeps the feed (and its connection) for the container's life; [name] names the
/// providers in the DevTools extension.
final class LiveFeed<T> {
  /// A feed over the connection [connect] returns.
  LiveFeed(
    LiveConnection<T> Function(Ref ref, String? lastEventId) connect, {
    LiveRules rules = const LiveRules(),
    String? name,
    bool keepAlive = false,
  }) {
    final spec = _Spec<T, Null>(
      (ref, _, lastEventId) => connect(ref, lastEventId),
      rules,
    );
    _LiveNotifier<T, Null> create() => _LiveNotifier<T, Null>(spec, null, this);
    final latest = keepAlive
        ? StreamNotifierProvider<_LiveNotifier<T, Null>, T>(
            create,
            name: name == null ? null : '$name.latest',
            retry: (_, _) => null,
          )
        : StreamNotifierProvider.autoDispose<_LiveNotifier<T, Null>, T>(
            create,
            name: name == null ? null : '$name.latest',
            retry: (_, _) => null,
          );
    _latest = latest;
    _status = keepAlive
        ? StreamProvider<LiveStatus>(
            (ref) => ref.watch(latest.notifier)._hub.stream,
            name: name == null ? null : '$name.status',
            retry: (_, _) => null,
          )
        : StreamProvider.autoDispose<LiveStatus>(
            (ref) => ref.watch(latest.notifier)._hub.stream,
            name: name == null ? null : '$name.status',
            retry: (_, _) => null,
          );
  }

  late final StreamNotifierProvider<_LiveNotifier<T, Null>, T> _latest;
  late final ProviderListenable<AsyncValue<LiveStatus>> _status;

  /// The last event, as an `AsyncValue`: loading until the first one, an error only when the
  /// connection ended with one (a refusal, `connect` that threw). Watching it is what opens the
  /// connection.
  ProviderListenable<AsyncValue<T>> get latest => _latest;

  /// Where the connection is: [LiveConnecting], [LiveOpen], [LivePaused], [LiveWaiting] or
  /// [LiveDone]. Watching it keeps the feed, and so its connection, alive.
  ProviderListenable<AsyncValue<LiveStatus>> get status => _status;
}

/// A [LiveFeed] per key (since 0.25.0): `orderLive(42)`, one connection per order watched.
///
/// ```dart
/// final orderLive = LiveFeedFamily<Order, int>(
///   (ref, id, lastEventId) => ServerEvents(
///     ref.watch(apiTransport),
///     Uri.parse('https://api.example.com/orders/$id/live'),
///     lastEventId: lastEventId,
///     name: 'order',
///   ).map((event) => Order.fromJson(jsonDecode(event.data) as Map<String, Object?>)),
///   rules: LiveRules(reconnectOn: [reconnectSignal, appShowSignal]),
/// );
///
/// // lib/app/orders/$id/data.dart
/// ProviderListenable<AsyncValue<Order>> data({required int id}) => orderLive(id);
/// ```
///
/// Each key behaves as a [LiveFeed] (auto-disposed when nothing watches it, its resume point kept
/// per key). A browser opens at most six HTTP/1.1 connections to one origin: a page that watches
/// many keys at once wants one feed for all of them, with the key in each event.
final class LiveFeedFamily<T, K> {
  /// A family over the connection [connect] returns for each key.
  LiveFeedFamily(
    LiveConnection<T> Function(Ref ref, K key, String? lastEventId) connect, {
    LiveRules rules = const LiveRules(),
    String? name,
  }) {
    final spec = _Spec<T, K>(connect, rules);
    final latest = StreamNotifierProvider.autoDispose
        .family<_LiveNotifier<T, K>, T, K>(
          (key) => _LiveNotifier<T, K>(spec, key, (this, key)),
          name: name == null ? null : '$name.latest',
          retry: (_, _) => null,
        );
    _latestOf = latest.call;
    _statusOf = StreamProvider.autoDispose
        .family<LiveStatus, K>(
          (ref, key) => ref.watch(latest(key).notifier)._hub.stream,
          name: name == null ? null : '$name.status',
          retry: (_, _) => null,
        )
        .call;
  }

  late final ProviderListenable<AsyncValue<T>> Function(K key) _latestOf;
  late final ProviderListenable<AsyncValue<LiveStatus>> Function(K key)
  _statusOf;

  /// The last event of [key]'s connection (see [LiveFeed.latest]).
  ProviderListenable<AsyncValue<T>> call(K key) => _latestOf(key);

  /// Where [key]'s connection is (see [LiveFeed.status]).
  ProviderListenable<AsyncValue<LiveStatus>> status(K key) => _statusOf(key);
}
