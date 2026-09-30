import 'package:flutter/material.dart';

/// Asks for `name`, so it gets the `$name` segment. Nobody gives it a type,
/// so it's a String.
class GreetPage extends StatelessWidget {
  const GreetPage({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) => Center(child: Text('Hello, $name'));
}
