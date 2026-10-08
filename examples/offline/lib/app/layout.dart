import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter/material.dart';
import 'package:offline/app.g.dart';
import 'package:offline/network.dart';
import 'package:offline/session.dart';
import 'package:offline/sync_notice.dart';

/// The frame of every page: the offline switch, what is waiting to send, and `autoSync`.
class RootLayout extends ConsumerWidget {
  const RootLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountId);
    final online = ref.watch(networkOnline);
    // Watched once, here: it syncs at start, on resume, on reconnect (the switch) and on the app's tick.
    // Its state drives the banner: isSyncing, and the last real report.
    final sync = ref.watch(autoSync);
    final waiting = ref.watch(pendingIntents(null)).value ?? const [];
    // The edits the server undid, from the last sync autoSync ran and the last one an action started.
    final undone = {
      for (final report in [sync.last, ref.watch(lastSync)])
        for (final u in report?.rolledBack ?? const <RolledBack>[])
          '${u.collection}/${u.id}: ${u.code}': u.code,
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline shop'),
        actions: [
          Text(online ? 'Online' : 'Offline'),
          Switch(
            key: const Key('network-switch'),
            value: online,
            onChanged: (value) =>
                ref.read(networkOnline.notifier).set(online: value),
          ),
          if (account != null)
            IconButton(
              key: const Key('sign-out'),
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout),
              onPressed: () => signOutAndWipe(ref),
            ),
        ],
      ),
      body: Column(
        children: [
          if (sync.isSyncing) const LinearProgressIndicator(),
          if (!online)
            const _Banner('You are offline. Changes are saved on this phone.'),
          if (waiting.isNotEmpty)
            _Banner(
              '${waiting.length} ${waiting.length == 1 ? 'change' : 'changes'} waiting to send',
            ),
          if (undone.isNotEmpty)
            _Banner(
              'The server undid ${undone.length} ${undone.length == 1 ? 'edit' : 'edits'} '
              '(${undone.values.toSet().join(', ')})',
            ),
          Expanded(
            child: account == null
                ? Center(
                    child: FilledButton(
                      onPressed: () =>
                          ref.read(accountId.notifier).signIn('ada'),
                      child: const Text('Sign in as ada'),
                    ),
                  )
                : child,
          ),
        ],
      ),
      bottomNavigationBar: account == null
          ? null
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () => const OrdersRoute().go(context),
                  child: const Text('Orders'),
                ),
                TextButton(
                  onPressed: () => const NotesRoute().go(context),
                  child: const Text('Notes'),
                ),
              ],
            ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.secondaryContainer,
    padding: const EdgeInsets.all(8),
    child: Text(text),
  );
}
