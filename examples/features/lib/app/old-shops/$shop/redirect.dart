import 'package:features/app.g.dart';

/// A route that only redirects: `/old-shops/acme` → `/shops/acme`. The folder
/// gets a typed route too, `OldShopsShopRoute(shop: 'acme')`.
String redirect({required String shop}) => ShopRoute(shop: shop).location;
