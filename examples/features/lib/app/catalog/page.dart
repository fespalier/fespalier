import 'package:flutter/material.dart';

class CatalogPage extends StatelessWidget {
  const CatalogPage({super.key, required this.featured});

  final List<String> featured;

  @override
  Widget build(BuildContext context) =>
      Text('Featured: ${featured.join(', ')}');
}
