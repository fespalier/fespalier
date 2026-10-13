import 'package:adopt/before/router_before.dart';
import 'package:adopt/shop.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

// The 0.11-style main(): the app owns its ProviderContainer, so it does by hand what
// startup.dart's ready() and attach() do from 0.12.0. Not an entry point (lib/main.dart is),
// but compiled, and test/parity_test.dart boots it.

/// What the old main() put in `runApp`. Split from [mainBefore] so a test can pump it.
Future<Widget> beforeRoot() async {
  final container = ProviderContainer();
  // -> ready(): the first route renders with the catalog loaded.
  await container.read(catalogProvider.future);
  final router = buildBeforeRouter();
  // -> attach(): a post-frame step that needs the router.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    container.listen(openProductProvider, (_, id) {
      if (id != null) router.go('/products/$id');
    });
  });
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
}

Future<void> mainBefore() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(await beforeRoot());
}
