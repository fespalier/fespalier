import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// The counter lives in this widget's state: it survives switching to Authors
/// and to another outer tab.
class BooksPage extends HookWidget {
  const BooksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final count = useState(0);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Books count ${count.value}'),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '+ book',
            onPressed: () => count.value++,
          ),
        ],
      ),
    );
  }
}
