import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// The app around the router.
class App extends StatelessWidget {
  const App({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Plugins',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    routerConfig: router,
  );
}
