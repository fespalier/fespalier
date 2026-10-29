import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:flutter/material.dart';
import 'package:live/requests.dart';
import 'package:live/wiring.dart';

/// What a connection's status means, in the words the banner shows.
String describeStatus(LiveStatus status) => switch (status) {
  LiveConnecting(attempt: 1) => 'Connecting',
  LiveConnecting(:final attempt) => 'Connecting (try $attempt)',
  LiveOpen(resumed: true) => 'Live, resumed from the last event',
  LiveOpen() => 'Live',
  LivePaused(connected: true) => 'Paused while hidden',
  LivePaused() => 'Closed while hidden: opens again when shown',
  LiveWaiting(:final drop, :final failures) =>
    'Disconnected (${drop.name}${failures > 1 ? ', $failures tries' : ''}): '
        'waits for the next tick',
  LiveDone(:final end) => 'Stopped (${end.name})',
};

/// A banner over a page with where its connection is.
class StatusBanner extends StatelessWidget {
  /// A banner for [status], or for a connection with no status yet.
  const StatusBanner(this.status, {super.key});

  /// The connection's status, if it has one.
  final LiveStatus? status;

  @override
  Widget build(BuildContext context) {
    final status = this.status;
    final scheme = Theme.of(context).colorScheme;
    final live = status is LiveOpen;
    return Container(
      width: double.infinity,
      color: live ? scheme.primaryContainer : scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        status == null ? 'Connecting' : describeStatus(status),
        key: const Key('status'),
      ),
    );
  }
}

/// A button that asks the server to do something (`POST <path>`): advance an order, drop a stream,
/// refuse tickets. It goes through the app's transport, to the demo server or to tool/server.dart.
class ServerButton extends ConsumerWidget {
  /// A button labelled [label] that posts to [path].
  const ServerButton(this.label, this.path, {super.key});

  /// What it says.
  final String label;

  /// The path it posts to, relative to the origin (`orders/1/advance`).
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) => OutlinedButton(
    onPressed: () async {
      try {
        await post(ref.read(liveTransport), ref.read(liveOrigin).resolve(path));
      } on Exception catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('The server did not do it: $error')),
        );
      }
    },
    child: Text(label),
  );
}

/// The server's buttons, under a heading that says what they stand for.
class ServerControls extends StatelessWidget {
  /// The [buttons].
  const ServerControls(this.buttons, {super.key});

  /// What the server can be asked to do here.
  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('On the server', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: buttons),
      ],
    ),
  );
}
