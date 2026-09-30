import 'package:flutter/material.dart';

class MembersNotFound extends StatelessWidget {
  const MembersNotFound({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) => Text('No member at ${uri.path}');
}
