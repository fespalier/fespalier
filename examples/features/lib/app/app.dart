import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// The app around the router. The generated main() (lib/app.main.g.dart) builds it once
/// startup.dart is done, and gives it the router.
class App extends StatelessWidget {
  const App({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) =>
      MaterialApp.router(routerConfig: router);
}
