import 'package:features/app.g.dart';
import 'package:flutter/material.dart';

/// Two scrollables, each under its own `PageStorageKey`: with `scroll_restoration: true`
/// in pubspec.yaml the browser's back and forward bring both offsets back (a `go` to this
/// page starts both at the top). A scrollable without a key would not be restored.
class FeedPage extends StatelessWidget {
  const FeedPage({super.key});

  @override
  Widget build(BuildContext context) => Column(
        children: [
          SizedBox(
            height: 56,
            child: ListView.builder(
              key: const PageStorageKey<String>('featured'),
              scrollDirection: Axis.horizontal,
              itemCount: 40,
              itemExtent: 120,
              itemBuilder: (_, i) => Center(child: Text('Featured $i')),
            ),
          ),
          TextButton(
            onPressed: () => const SearchRoute().go(context),
            child: const Text('Search'),
          ),
          Expanded(
            child: ListView.builder(
              key: const PageStorageKey<String>('feed'),
              itemCount: 100,
              itemExtent: 56,
              itemBuilder: (_, i) => ListTile(title: Text('Item $i')),
            ),
          ),
        ],
      );
}
