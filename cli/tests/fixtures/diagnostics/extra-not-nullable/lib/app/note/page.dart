import 'package:flutter/widgets.dart';

class NotePage extends StatelessWidget {
  const NotePage({super.key, required this.extra});

  final String extra;

  @override
  Widget build(BuildContext context) => Text(extra);
}
