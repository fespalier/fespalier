import 'package:flutter/material.dart';

/// Below a localized folder and a `$segment`, and localized itself: /help/routing/examples,
/// /aide/routing/exemples, /hilfe/routing/beispiele, and any mix of them.
class HelpExamplesPage extends StatelessWidget {
  const HelpExamplesPage({super.key, required this.topic});

  final String topic;

  @override
  Widget build(BuildContext context) => Text('Examples of $topic');
}
