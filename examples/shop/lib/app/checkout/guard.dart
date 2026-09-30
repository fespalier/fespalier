import 'package:shop/app.g.dart';
import 'package:shop/cart.dart';
import 'package:trellis/trellis.dart';

/// No checkout with an empty cart.
GuardResult guard(ProviderContainer c, Params params) =>
    c.read(cartProvider).isEmpty ? const CartRoute().location : null;
