import 'package:flutter/material.dart';

/// The counter lives in this widget's state, which the tab keeps while you
/// look at another one. It is a `RestorableInt`, so it also survives the app
/// being killed and restored (when the router has a `restorationScopeId`).
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with RestorationMixin {
  final _count = RestorableInt(0);

  @override
  String? get restorationId => 'search';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_count, 'count');
  }

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Search count ${_count.value}'),
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '+',
              onPressed: () => setState(() => _count.value++),
            ),
          ],
        ),
      );
}
