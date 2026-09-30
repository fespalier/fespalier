import 'package:flutter/material.dart';
import 'package:shop/app.g.dart';
import 'package:trellis/trellis.dart';

class NotFound extends NotFoundView {
  const NotFound(super.uri, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Nothing at ${uri.path}'),
            TextButton(
              onPressed: () => const HomeRoute().go(context),
              child: const Text('Home'),
            ),
          ],
        ),
      );
}
