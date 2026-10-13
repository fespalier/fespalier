import 'package:flutter/widgets.dart';

class UserPage extends StatelessWidget {
  const UserPage({super.key, required this.id});

  final Uri id;

  @override
  Widget build(BuildContext context) => Text('$id');
}
