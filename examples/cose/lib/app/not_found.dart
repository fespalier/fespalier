import 'package:flutter/material.dart';

/// Shown for a location that matches no page.
class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('Nothing here')));
}
