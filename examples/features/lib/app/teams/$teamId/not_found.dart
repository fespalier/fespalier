import 'package:flutter/material.dart';

/// A not_found.dart in a folder covers the unknown paths under it; a
/// deeper one (members/) wins where there is one.
class TeamNotFound extends StatelessWidget {
  const TeamNotFound({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) => Text('No team page at ${uri.path}');
}
