import 'package:flutter/material.dart';

/// Shown when no route matches, `/xx` included: `$lang` is an enum, so an unknown language is not
/// a page. It sits above the language, so the route cannot translate it.
class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('Nothing at ${uri.path}')));
}
