import 'package:flutter/material.dart';
import 'package:fespalier/fespalier.dart';

import 'app.g.dart';

final _router = AppRoutes.router();

void main() => runApp(
  // pubspec.yaml has `data_retry: none`, so failures reach error.dart at
  // once instead of going through Riverpod 3's retries.
  const ProviderScope(child: ShopApp()),
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
