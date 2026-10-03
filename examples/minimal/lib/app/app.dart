import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// The app around the router: the title and the theme. This is the app.dart that `fsp init`
/// writes, plus a theme; the generated main() (lib/app.main.g.dart) builds it and gives it
/// the router.
class App extends StatelessWidget {
  const App({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Minimal',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    routerConfig: router,
  );
}
