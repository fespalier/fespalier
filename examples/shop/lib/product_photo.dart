import 'package:fespalier_image/fespalier_image.dart';
import 'package:flutter/material.dart';
import 'package:shop/api.dart';

/// The size of a product's photo in the list, and on its page (logical pixels). The page's
/// photo is precached at [pagePhotoSize] when a row is hovered, so both sides use one constant:
/// the precache then loads the very URL the page asks for.
const rowPhotoSize = 40.0;
const pagePhotoSize = 160.0;

/// A product's photo, round, [size] wide: a `ResponsiveImage` of the product's [Product.image],
/// square (`aspectRatio: 1`, so the CDN crops to it). While it loads, and when it fails (no image
/// server is running, say), it shows the product's initial, as the avatar did before there were
/// photos.
class ProductPhoto extends StatelessWidget {
  const ProductPhoto(this.product, {super.key, required this.size});

  final Product product;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = CircleAvatar(
      radius: size / 2,
      child: Text(product.name[0]),
    );
    return ClipOval(
      child: ResponsiveImage(
        product.image,
        width: size,
        height: size,
        // The name is right beside it.
        excludeFromSemantics: true,
        placeholder: (context) => initial,
        errorBuilder: (context, error, retry) => initial,
      ),
    );
  }
}
