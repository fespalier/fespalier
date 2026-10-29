import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:flutter/material.dart';
import 'package:live/app.g.dart';
import 'package:live/wiring.dart';

/// The frame of every page: which server the app talks to, **Tick now**, and the four screens.
class RootLayout extends ConsumerWidget {
  const RootLayout({super.key, required this.child});

  final Widget child;

  static const _tabs = [
    (to: OrdersRoute(), label: 'Orders', icon: Icons.local_shipping_outlined),
    (to: InboxRoute(), label: 'Inbox', icon: Icons.inbox_outlined),
    (to: AskRoute(), label: 'Ask', icon: Icons.auto_awesome_outlined),
    (to: ChatRoute(), label: 'Chat', icon: Icons.forum_outlined),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = GoRouterState.of(context).uri.path;
    final selected = _tabs.indexWhere(
      (tab) => path.startsWith(tab.to.location),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live'),
        actions: [
          // What the app's timer does every 15 s (lib/ticker.dart), now: a feed that dropped opens again.
          IconButton(
            tooltip: 'Tick now',
            icon: const Icon(Icons.update),
            onPressed: () => ref.read(streamTicker.notifier).fire(),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              usesRealServer
                  ? 'Server $liveOriginDefine, through $liveClientDefine'
                  : 'Demo server, in this app',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: child),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected < 0 ? 0 : selected,
        onDestinationSelected: (index) => _tabs[index].to.go(context),
        destinations: [
          for (final tab in _tabs)
            NavigationDestination(icon: Icon(tab.icon), label: tab.label),
        ],
      ),
    );
  }
}
