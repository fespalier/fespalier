import 'package:flutter/widgets.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.data});

  final int data;

  @override
  Widget build(BuildContext context) => Text('$data');
}
