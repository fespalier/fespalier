import 'package:adopt/router.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// The app around the router. The generated main() (lib/app.main.g.dart) builds it with the
/// router below.
class App extends StatelessWidget {
  const App({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Adopt',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    routerConfig: router,
  );
}

/// How the router is built, once, after startup.dart's `ready()`. The docs say to return
/// `AppRoutes.router()`; an app that adopts fespalier returns its own `GoRouter` instead, with
/// `AppRoutes.mount(at: '/shop')` among its routes (lib/router.dart). `fsp` reads the signature
/// (`GoRouter router()`, no parameters) and nothing of the body, so the generated main() keeps
/// working: `ready()` and `attach()` in startup.dart run around this router as around any other.
GoRouter router() => buildRouter();
