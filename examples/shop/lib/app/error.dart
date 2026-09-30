import 'package:flutter/material.dart';
import 'package:trellis/trellis.dart';

class RootError extends ErrorView<Params> {
  const RootError(super.params, super.failure, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
        child: TextButton.icon(
          onPressed: failure.retry,
          icon: const Icon(Icons.refresh),
          label: Text('${failure.error}'),
        ),
      );
}
