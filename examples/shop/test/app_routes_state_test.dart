import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/app.g.dart';

// AppRoutes remembers the last mount() (base, root navigator key). A bare mount() is the
// reset a test ends with, so no test depends on which ran before it.
void main() {
  tearDown(AppRoutes.mount);

  test('a mount without a key does not keep the one passed earlier', () {
    final host = GlobalKey<NavigatorState>(debugLabel: 'host');
    AppRoutes.mount(at: '/shop', navigatorKey: host);
    expect(AppRoutes.rootNavigatorKey, same(host));
    expect(AppRoutes.base, '/shop');

    AppRoutes.mount();
    expect(AppRoutes.rootNavigatorKey, isNot(same(host)));
    expect(AppRoutes.base, '/');
  });

  test('router() and mount() take a fresh key when given none', () {
    final first = AppRoutes.router();
    addTearDown(first.dispose);
    final firstKey = AppRoutes.rootNavigatorKey;
    final second = AppRoutes.router();
    addTearDown(second.dispose);
    expect(AppRoutes.rootNavigatorKey, isNot(same(firstKey)));
    expect(
        second.routerDelegate.navigatorKey, same(AppRoutes.rootNavigatorKey));
    expect(first.routerDelegate.navigatorKey, same(firstKey));

    AppRoutes.mount();
    expect(AppRoutes.rootNavigatorKey, isNot(same(firstKey)));
  });

  test('router() given a key uses it, and the next call forgets it', () {
    final mine = GlobalKey<NavigatorState>(debugLabel: 'mine');
    final router = AppRoutes.router(navigatorKey: mine);
    addTearDown(router.dispose);
    expect(AppRoutes.rootNavigatorKey, same(mine));
    expect(router.routerDelegate.navigatorKey, same(mine));

    AppRoutes.mount();
    expect(AppRoutes.rootNavigatorKey, isNot(same(mine)));
  });
}
