import 'package:flutter/material.dart';

class TicksPage extends StatelessWidget {
  const TicksPage({super.key, required this.data});

  final int data;

  @override
  Widget build(BuildContext context) => Text('Tick $data');
}
