import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

import 'app.g.dart';

final _router = AppRoutes.router();

void main() => runApp(
  ProviderScope(
    retry: (retryCount, error) => null,
    child: MaterialApp.router(routerConfig: _router),
  ),
);
