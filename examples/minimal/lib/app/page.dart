import 'package:flutter/material.dart';
import 'package:minimal/app.g.dart';

/// page.dart in lib/app/ is served at `/`. This one is a widget class; the
/// route is named after it (HomePage → HomeRoute).
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => Material(
    // Pages sit below the layout's Scaffold, so give ListTile ink a surface
    // of its own (page transitions paint in between).
    type: MaterialType.transparency,
    child: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Hello from fespalier',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        // Typed routes: the compiler checks the arguments, and the URL
        // (`/items/2?qty=3`) is written for you.
        ListTile(
          title: const Text('Item 1'),
          subtitle: const Text('/items/1'),
          onTap: () => const ItemRoute(id: 1).go(context),
        ),
        ListTile(
          title: const Text('Item 2, three of them'),
          subtitle: const Text('/items/2?qty=3'),
          onTap: () => const ItemRoute(id: 2, qty: 3).go(context),
        ),
        ListTile(
          title: const Text('Item 99, which does not exist'),
          subtitle: const Text('/items/99 shows error.dart'),
          onTap: () => const ItemRoute(id: 99).go(context),
        ),
      ],
    ),
  );
}
