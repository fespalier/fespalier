import 'package:fespalier_image/fespalier_image.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

/// Product photos come from an EmgR (vaam-apps/image-resizer) on this computer, unsigned: run it
/// with `ALLOW_UNSIGNED_REQUESTS=true` and `ALLOWED_SOURCES` set to the photos' origin
/// (docs/responsive-images.md, "Images"). A production app has its backend sign them instead, and returns each photo
/// as a srcset (`SrcsetUrlBuilder`): a signing key never goes in an app. `--dart-define=SHOP_IMAGES=...`
/// and `--dart-define=SHOP_IMAGE_SOURCE=...` point it elsewhere. Without a server the photos fail,
/// and each shows the product's initial.
///
/// The photos are fetched through [transport] (since 0.21.0), the app's one, so a photo request is
/// signed, traced and counted like the others: that is why the CDN is no longer `const`.
ImageCdn shopImages(HttpTransport transport) => ImageCdn(
      builder: const ImgproxyUrlBuilder.emgr(
        baseUrl: String.fromEnvironment(
          'SHOP_IMAGES',
          defaultValue: 'http://localhost:13001',
        ),
        sourceBase: String.fromEnvironment(
          'SHOP_IMAGE_SOURCE',
          defaultValue: 'https://images.example.com/',
        ),
      ),
      transport: transport,
    );
