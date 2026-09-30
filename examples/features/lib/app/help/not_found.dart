import 'package:flutter/material.dart';

/// A not_found.dart under a localized folder covers its every spelling: /help/x/y/z,
/// /aide/x/y/z and /hilfe/x/y/z.
class HelpNotFound extends StatelessWidget {
  const HelpNotFound({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) => Text('No help at ${uri.path}');
}
