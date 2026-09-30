import 'package:flutter/material.dart';
import 'package:minimal/items.dart';

/// `$id` in the folder name is a path segment: /items/1, /items/2, ...
///
/// Each constructor parameter is filled by name or by type:
///  - `item` is required and is what data.dart returns, so it is the loaded data;
///  - `qty` is optional and nullable, so it is the query parameter `?qty=`
///    (null when it is missing or not a number).
class ItemPage extends StatelessWidget {
  const ItemPage({super.key, required this.item, this.qty});

  final Item item;
  final int? qty;

  @override
  Widget build(BuildContext context) =>
      Center(child: Text('${qty ?? 1} × ${item.name} (#${item.id})'));
}
