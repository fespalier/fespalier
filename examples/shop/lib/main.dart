import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:fespalier/fespalier.dart';

import 'app.g.dart';

final _router = AppRoutes.router();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // /checkout and /products/:id are deferred routes: on the web each is a chunk the browser
  // fetches when it is needed (or ahead of time, when a link to it is hovered). Elsewhere the
  // code is already in the app, so load it here, before the first frame, and a page never
  // shows loading.dart for it.
  if (!kIsWeb) await AppRoutes.loadDeferred();
  runApp(
    // pubspec.yaml has `data_retry: none`, so failures reach error.dart at
    // once instead of going through Riverpod 3's retries.
    const ProviderScope(child: ShopApp()),
  );
}

class ShopApp extends StatelessWidget {
  const ShopApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'Shop',
        theme: ThemeData(colorSchemeSeed: Colors.teal),
        routerConfig: _router,
      );
}
