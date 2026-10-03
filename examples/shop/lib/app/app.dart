import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// The app around the router: the title and the theme. The generated main()
/// (lib/app.main.g.dart) builds it, gives it the router, and wraps it in the `ProviderScope`.
///
/// pubspec.yaml has `data_retry: none`, so a failing data() reaches error.dart at once
/// instead of going through Riverpod 3's retries.
class App extends StatelessWidget {
  const App({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'Shop',
        theme: ThemeData(colorSchemeSeed: Colors.teal),
        routerConfig: router,
      );
}
