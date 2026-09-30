import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// A route shown as a modal bottom sheet (see transition.dart).
class SortPage extends StatelessWidget {
  const SortPage({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Sort photos by'),
        ListTile(title: const Text('Newest'), onTap: () => context.pop()),
      ],
    ),
  );
}
