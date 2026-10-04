// What the route smoke tests (routes_test.dart, written by `fsp test`) boot with. This file is
// the app's: `fsp test` only looks for the two functions it may export, `overrides` and `app`.
import 'package:fespalier/testing.dart';
import 'package:shop/api.dart';
import 'package:shop/cart.dart';

import '../images.dart';

/// The providers the test of [pattern] (`/checkout`) boots with. Called once per test, so every
/// test gets a fresh fake.
List<Override> overrides(String pattern) => [
      apiProvider.overrideWithValue(FakeApi()),
      // The product photos load through fakes: no network, and no fake HttpClient.
      fakeImages(),
      // checkout/guard.dart sends an empty cart back to /cart: this one has a line.
      if (pattern == '/checkout') cartProvider.overrideWith(_FullCart.new),
    ];

class _FullCart extends Cart {
  @override
  Map<int, CartLine> build() => const {
        1: CartLine(Product(1, 'Coffee beans, 500 g', 9.5), 1),
      };
}
