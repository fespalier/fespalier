// Written by `fsp test` from lib/app/: don't edit it, run `fsp test` again.
// dart format off
// ignore_for_file: type=lint, unused_import
//
// A widget smoke test per route: each opens the route at a sample URL with pumpRouter and
// waits, on the test's fake clock, until its page is on screen. Provider overrides come
// from test/routes/setup.dart.

import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/app.g.dart';

import 'setup.dart' as setup;

void main() {
  testWidgets(
    '/ at /',
    (tester) => smokeTestRoute(
      tester,
      '/',
      AppRoutes.router(
        initialLocation: '/',
      ),
      overrides: setup.overrides(
        '/',
      ),
    ),
  );
  testWidgets(
    '/cart at /cart',
    (tester) => smokeTestRoute(
      tester,
      '/cart',
      AppRoutes.router(
        initialLocation: '/cart',
      ),
      overrides: setup.overrides(
        '/cart',
      ),
    ),
  );
  // Guarded by checkout/guard.dart.
  testWidgets(
    '/checkout at /checkout',
    (tester) => smokeTestRoute(
      tester,
      '/checkout',
      AppRoutes.router(
        initialLocation: '/checkout',
      ),
      overrides: setup.overrides(
        '/checkout',
      ),
    ),
  );
  testWidgets(
    '/greet/:name at /greet/Ada',
    (tester) => smokeTestRoute(
      tester,
      '/greet/:name',
      AppRoutes.router(
        initialLocation: '/greet/Ada',
      ),
      overrides: setup.overrides(
        '/greet/:name',
      ),
    ),
  );
  testWidgets(
    '/products at /products',
    (tester) => smokeTestRoute(
      tester,
      '/products',
      AppRoutes.router(
        initialLocation: '/products',
      ),
      overrides: setup.overrides(
        '/products',
      ),
    ),
  );
  testWidgets(
    '/products/:id at /products/1',
    (tester) => smokeTestRoute(
      tester,
      '/products/:id',
      AppRoutes.router(
        initialLocation: '/products/1',
      ),
      overrides: setup.overrides(
        '/products/:id',
      ),
    ),
  );
}
