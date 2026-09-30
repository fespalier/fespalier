import 'package:flutter/material.dart';

/// A layout can ask for the segments above it.
class ShopLayout extends StatelessWidget {
  const ShopLayout({super.key, required this.shop, required this.child});

  final String shop;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text('Shop: $shop'),
          Expanded(child: child),
        ],
      );
}
