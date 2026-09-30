import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:minimal/app.g.dart';

// This is the main.dart that `fsp init` prints, plus a title and a theme.
// AppRoutes.router() is the whole router: it is generated from lib/app/.
void main() => runApp(
  ProviderScope(
    child: MaterialApp.router(
      title: 'Minimal',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      routerConfig: AppRoutes.router(),
    ),
  ),
);
