import 'package:flutter/material.dart';

/// `$$rest` matches one or more segments: `/docs/guide/setup` is
/// `['guide', 'setup']`. `/docs` alone is the page above.
class DocsPage extends StatelessWidget {
  const DocsPage({super.key, required this.rest});

  final List<String> rest;

  @override
  Widget build(BuildContext context) => Text('Doc ${rest.join(' > ')}');
}
