import 'package:flutter/material.dart';

/// Catches any other top-level path. Static routes (and groups of them) are
/// tried first, so /profile and /search never land here.
class SlugPage extends StatelessWidget {
  const SlugPage({super.key, required this.slug});

  final String slug;

  @override
  Widget build(BuildContext context) => Text('Page $slug');
}
