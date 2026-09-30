import 'package:flutter/material.dart';

class RootLayout extends StatelessWidget {
  const RootLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(body: child);
}
