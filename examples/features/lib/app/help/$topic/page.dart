import 'package:flutter/material.dart';

class HelpTopicPage extends StatelessWidget {
  const HelpTopicPage({super.key, required this.topic});

  final String topic;

  @override
  Widget build(BuildContext context) => Text('Help topic $topic');
}
