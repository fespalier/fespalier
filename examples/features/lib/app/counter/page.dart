import 'package:features/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

class CounterPage extends ConsumerWidget {
  const CounterPage({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    onPressed: () => ref.read(CounterRoute.data.notifier).increment(),
    child: Text('Count $count'),
  );
}
