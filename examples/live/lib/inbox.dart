import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:live/requests.dart';
import 'package:live/wiring.dart';

/// What the inbox's stream says: thread [thread] changed. Only that: the page reads the thread again.
final class ThreadChanged {
  /// A change to [thread].
  const ThreadChanged(this.thread);

  /// The thread's id.
  final String thread;
}

/// Each event's JSON `data` (`{"thread": "t1"}`) as a [ThreadChanged]. A message it cannot read is
/// skipped and counted, never the end of the stream.
final threadCodec = EventCodec<ServerEvent, ThreadChanged>(
  (event) => ThreadChanged(
    (jsonDecode(event.data) as Map<String, Object?>)['thread']! as String,
  ),
);

/// The inbox's changes: one event stream for every thread, held once for the container's life.
///
/// The server sends no `id:`, so a reconnection cannot ask for what it missed: every reopen after a
/// drop is a **gap**, and every watched thread reloads once, at that moment, without waiting for an
/// event. A drop waits for the network to come back, the app to be shown again, or the tick.
final inboxChanges = ChangeFeed<ThreadChanged>.live(
  (ref, lastEventId) => ServerEvents(
    ref.watch(liveTransport),
    ref.watch(liveOrigin).resolve('inbox/changes'),
    lastEventId: lastEventId,
    name: 'inbox',
  ).transform(threadCodec),
  rules: LiveRules(
    reconnectOn: [reconnectSignal, appShowSignal],
    idle: liveIdle,
  ),
  name: 'inboxChanges',
);

/// Moves when thread `id` changed, and on no other event: watching it is the invalidation.
final threadChanged = inboxChanges.topic<String>(
  (event, id) => event.thread == id,
);

/// A thread of the inbox: its id and title. Each row reads the rest itself, live ([thread]).
final class ThreadSummary {
  /// Thread [id], called [title].
  const ThreadSummary(this.id, this.title);

  /// Its id.
  final String id;

  /// What the inbox shows.
  final String title;
}

/// A thread as the server has it now.
final class Thread {
  /// Reads `GET /inbox/<id>`'s JSON.
  Thread.fromJson(Map<String, Object?> json)
    : id = json['id']! as String,
      title = json['title']! as String,
      messages = json['messages']! as int,
      reads = json['reads']! as int;

  /// Its id.
  final String id;

  /// What the inbox shows.
  final String title;

  /// How many messages it has.
  final int messages;

  /// How many times the server was asked for it: each reload adds one, so a gap shows on every row.
  final int reads;
}

/// One thread, read again whenever [threadChanged] says it changed (and once per gap).
final thread = FutureProvider.autoDispose.family<Thread, String>((
  ref,
  id,
) async {
  ref.watch(threadChanged(id));
  final json = await getJson(
    ref.watch(liveTransport),
    ref.watch(liveOrigin).resolve('inbox/$id'),
  );
  return Thread.fromJson(json! as Map<String, Object?>);
}, retry: (_, _) => null);
