import 'package:adopt/app.g.dart';
import 'package:adopt/boot_log.dart';
import 'package:adopt/shop.dart';
import 'package:fespalier/fespalier.dart';

// Since 0.12.0 (docs/migration.md, "0.12.0"). This is what the 0.11-style main() in
// lib/before/main_before.dart did between `ProviderContainer()` and `runApp`, and after the
// first frame. The order is zone() -> startup() -> the container -> ready() -> the router
// (app.dart's router()) -> attach().

/// Runs on the app's own container, before the router exists: no route has matched, no guard
/// has run and no data() has been read. The first route finds the catalog loaded.
///
/// The catalog is a plain `FutureProvider`, which stays alive. A `@riverpod` (auto-dispose)
/// provider would need `container.listen(provider, (_, _) {})` here, or it would be gone before
/// the first route reads it.
Future<void> ready(ProviderContainer container) async {
  bootLog.add('ready');
  await container.read(catalogProvider.future);
}

/// After the first frame that shows the router: the step the old main() put in a post-frame
/// callback because it needed the router. `openProductProvider` is set from outside the widget
/// tree (a notification handler, say); this sends it to the typed route.
void attach(GoRouter router, ProviderContainer container) {
  bootLog.add('attach');
  container.listen(openProductProvider, (_, id) {
    if (id != null) router.go(ProductRoute(id: id).location);
  });
}
