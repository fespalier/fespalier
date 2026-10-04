import 'dart:ui' as ui;

import 'package:fespalier/fespalier.dart' show ProviderScope;
import 'package:fespalier_image/fespalier_image.dart';
import 'package:fespalier_image/src/variants.dart';
import 'package:fespalier_image/src/warnings.dart';
import 'package:fespalier_image/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// EmgR on this computer, unsigned: what the shop uses.
const emgr = ImageCdn(
  builder: ImgproxyUrlBuilder.emgr(
    baseUrl: 'http://localhost:13001',
    sourceBase: 'https://images.example.com/',
  ),
);

/// `https://images.example.com/products/N.jpg` in URL-safe base64 without padding.
const b64Product1 = 'aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcHJvZHVjdHMvMS5qcGc';
const b64Product2 = 'aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcHJvZHVjdHMvMi5qcGc';
const b64Product3 = 'aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcHJvZHVjdHMvMy5qcGc';

/// The EmgR URL of `products/3.jpg` at [width] (with a square [height], or without one).
String productUrl(int width, {int? height, String b64 = b64Product3}) =>
    'http://localhost:13001/unsigned/'
    'rs:${height == null ? 'fit' : 'fill'}:$width:${height ?? 0}/$b64.webp';

/// An image to hand [FakeImages], made once per file (`setUpAll`).
late ui.Image testImage;

Future<void> makeTestImage() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  testImage = await createTestImage(width: 8, height: 8);
}

/// Forgets what an earlier test registered or printed.
void resetImageState() {
  ImageVariants.clear();
  resetImageWarnings();
}

/// [child] in the top-left corner of an app whose CDN is [cdn] loading through [fakes].
Widget imageApp(FakeImages fakes, Widget child, {ImageCdn cdn = emgr}) =>
    ProviderScope(
      overrides: [imageCdnProvider.overrideWithValue(fakes.cdn(cdn))],
      child: MaterialApp(
        home: Scaffold(
          body: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    );

/// A placeholder a test can find.
Widget testPlaceholder(BuildContext context) =>
    const SizedBox(key: Key('placeholder'));

Finder get placeholder => find.byKey(const Key('placeholder'));
