import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// The counter lives in this widget's state, which the tab keeps while you
/// look at another one.
class SearchPage extends HookWidget {
  const SearchPage({super.key});

  @override
  Widget build(BuildContext context) {
    final count = useState(0);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Search count ${count.value}'),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '+',
            onPressed: () => count.value++,
          ),
        ],
      ),
    );
  }
}
