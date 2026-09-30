import 'package:fespalier/fespalier.dart';
import 'package:shop/app.g.dart';
import 'package:shop/cart.dart';

/// No checkout with an empty cart.
GuardResult guard(ProviderContainer c) =>
    c.read(cartProvider).isEmpty ? const CartRoute().location : null;
