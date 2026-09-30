import 'package:features/models/category.dart' as models;
import 'package:flutter/material.dart';

/// A catch-all can be a `List` of an enum, too: `/browse/shoes/hats` is
/// `[Category.shoes, Category.hats]` and `/browse/shoes/socks` is not found. The enum
/// can come in under an import prefix.
class BrowsePage extends StatelessWidget {
  const BrowsePage({super.key, required this.categories, required this.data});

  final List<models.Category> categories;

  /// What data.dart yields: how many different categories.
  final int data;

  @override
  Widget build(BuildContext context) => Text(
    'Browse ${categories.map((c) => c.name).join(' + ')} ($data different)',
  );
}
