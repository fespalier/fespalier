import 'package:flutter/material.dart';
import 'package:shop/app.g.dart';

class NotFound extends StatelessWidget {
  const NotFound({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) => Center(
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
