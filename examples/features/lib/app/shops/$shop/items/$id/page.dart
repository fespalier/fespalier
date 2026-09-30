import 'package:flutter/material.dart';

/// `label` is neither a segment nor called `data`: it gets data.dart's value
/// because its type (String) is what data.dart yields.
class ItemPage extends StatelessWidget {
  const ItemPage(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Text('Item $label');
}
