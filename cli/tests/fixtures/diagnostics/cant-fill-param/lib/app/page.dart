import 'package:flutter/widgets.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(label);
}
