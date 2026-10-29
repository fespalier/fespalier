import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:live/inbox.dart';
import 'package:live/widgets.dart';

/// The inbox, kept current by one change feed (`inboxChanges`, a `ChangeFeed.live` over an event
/// stream): each row watches its thread's topic, so a change to one thread reloads that row and no
/// other. The server sends no event IDs, so a reopen after a drop is a gap, and every row reloads once:
/// watch "read N times" move on each row.
class InboxPage extends ConsumerWidget {
  const InboxPage({super.key, required this.threads});

  /// What data.dart's `Future<List<ThreadSummary>>` yields, by type.
  final List<ThreadSummary> threads;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A ChangeFeed.live has no status: a refusal is an error of its `latest`.
    final stopped = ref.watch(
      inboxChanges.latest.select((value) => value.hasError),
    );
    return ListView(
      children: [
        if (stopped)
          Container(
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.all(16),
            child: const Text('Live updates stopped: the server refused them'),
          ),
        for (final summary in threads) _ThreadTile(summary),
        ServerControls([
          for (final summary in threads)
            ServerButton(
              'New message in ${summary.title}',
              'inbox/${summary.id}/post',
            ),
          const ServerButton('Drop the connection', 'inbox/drop'),
        ]),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'A new message reloads its thread only. A drop waits for the next tick (every 15 s, or Tick '
            'now); the server sends no event IDs, so that reopen is a gap and every thread reloads once.',
          ),
        ),
      ],
    );
  }
}

class _ThreadTile extends ConsumerWidget {
  const _ThreadTile(this.summary);

  final ThreadSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(thread(summary.id));
    final loaded = value.value;
    return ListTile(
      title: Text(summary.title),
      subtitle: Text(switch ((loaded, value.error)) {
        (final Thread t, _) =>
          '${_count(t.messages, 'message')}, read ${_count(t.reads, 'time')}',
        (null, final Object error) => 'Could not read it: $error',
        _ => 'Reading',
      }),
    );
  }
}

String _count(int n, String noun) => '$n ${n == 1 ? noun : '${noun}s'}';
