/// Network images sized by their layout and fetched through an image CDN (since 0.9.0).
///
/// `ResponsiveImage` asks the app's `ImageCdn` (`imageCdnProvider`) for an image at the width its
/// box needs, rounded up to one of a few buckets; the URL builders write the URL for imgproxy and
/// EmgR, Cloudinary, imgix, Thumbor, a template or a srcset. The package takes no signing key:
/// read "Signed image URLs" in the README before putting a CDN in front of an app.
library;

export 'src/buckets.dart';
export 'src/builder.dart';
export 'src/builders/cloudinary.dart';
export 'src/builders/direct.dart';
export 'src/builders/imgix.dart';
export 'src/builders/imgproxy.dart';
export 'src/builders/srcset.dart';
export 'src/builders/template.dart';
export 'src/builders/thumbor.dart';
export 'src/cdn.dart';
export 'src/heroes.dart';
export 'src/request.dart';
export 'src/responsive_image.dart';
