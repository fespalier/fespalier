import 'package:flutter/material.dart';

/// Shown while data.dart is loading (the first signed call also registers the device key).
class HomeLoading extends StatelessWidget {
  const HomeLoading({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
