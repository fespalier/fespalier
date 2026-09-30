import 'package:trellis/trellis.dart';

import 'api.dart';

class CartLine {
  const CartLine(this.product, this.qty);

  final Product product;
  final int qty;
}

final cartProvider = NotifierProvider<Cart, Map<int, CartLine>>(Cart.new);

final cartCountProvider = Provider(
  (ref) => ref.watch(cartProvider).values.fold(0, (n, line) => n + line.qty),
);

class Cart extends Notifier<Map<int, CartLine>> {
  @override
  Map<int, CartLine> build() => const {};

  void add(Product p, int qty) {
    final current = state[p.id]?.qty ?? 0;
    state = {...state, p.id: CartLine(p, current + qty)};
  }

  void clear() => state = const {};
}
