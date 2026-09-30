import 'package:flutter/material.dart';

/// Shown while data.dart is loading. A loading.dart is inherited by the
/// folders below it; this one only has a single page to cover.
class ItemLoading extends StatelessWidget {
  const ItemLoading({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}
