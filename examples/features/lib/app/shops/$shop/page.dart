import 'package:flutter/material.dart';

class ShopPage extends StatelessWidget {
  const ShopPage({super.key, required this.shop});

  final String shop;

  @override
  Widget build(BuildContext context) => Text('Welcome to $shop');
}
