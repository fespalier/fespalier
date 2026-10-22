import 'package:flutter/material.dart';

/// Shown while a page's data.dart is loading for the first time.
class RootLoading extends StatelessWidget {
  const RootLoading({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
