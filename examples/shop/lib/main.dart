import 'package:flutter/material.dart';
import 'package:fespalier/fespalier.dart';

import 'app.g.dart';

final _router = AppRoutes.router();

void main() => runApp(
      ProviderScope(
        // Surface failures in error.dart instead of Riverpod 3's silent retries.
        retry: (retryCount, error) => null,
        child: const ShopApp(),
      ),
    );

class ShopApp extends StatelessWidget {
  const ShopApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'Shop',
        theme: ThemeData(colorSchemeSeed: Colors.teal),
        routerConfig: _router,
      );
}
