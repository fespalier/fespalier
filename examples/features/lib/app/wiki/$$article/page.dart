import 'package:flutter/material.dart';

class WikiPage extends StatelessWidget {
  const WikiPage({super.key, required this.article, required this.data});

  final List<String> article;
  final String data;

  @override
  Widget build(BuildContext context) => Text('$data (${article.length} parts)');
}
