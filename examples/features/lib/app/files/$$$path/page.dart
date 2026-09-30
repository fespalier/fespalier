import 'package:flutter/material.dart';

/// `$$$path` (three `$`) is an optional catch-all: `/files` and `/files/a/b`.
class FilesPage extends StatelessWidget {
  const FilesPage({super.key, this.path = const []});

  final List<String> path;

  @override
  Widget build(BuildContext context) =>
      Text(path.isEmpty ? 'Files root' : 'File ${path.join('/')}');
}
