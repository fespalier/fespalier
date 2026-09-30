import 'package:features/models/category.dart';
import 'package:flutter/material.dart';

/// An enum declared in the page's own file can be a query parameter (`?sort=price`).
/// `fsp gen` finds it by reading this file, so a type that is no enum, or that it can't
/// find, is an error rather than a guess.
enum Sort { price, name }

/// `$category` is a `Category`: the name of a value, read by name (in any case here,
/// as this app matches paths that way). `Sort? sort` is a query parameter that is null
/// when it is missing or names no value.
class CategoryShopPage extends StatelessWidget {
  const CategoryShopPage({
    super.key,
    required this.category,
    required this.items,
    this.sort,
  });

  final Category category;

  /// What data.dart yields, by type.
  final List<String> items;
  final Sort? sort;

  @override
  Widget build(BuildContext context) {
    final shown = sort == Sort.name ? ([...items]..sort()) : items;
    return Column(
      children: [
        Text('Shop ${category.name}: ${shown.join(', ')}'),
        Text('sorted by ${sort?.name ?? 'default'}'),
      ],
    );
  }
}
