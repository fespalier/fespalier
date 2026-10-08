import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// The app around the router. The generated main() builds it once startup.dart is done.
class App extends StatelessWidget {
  const App({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Offline example',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    routerConfig: router,
  );
}
