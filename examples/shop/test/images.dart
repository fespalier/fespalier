// Product photos in a test: loads through `FakeImages`, which record each URL and complete when the
// test says (or at once, with an image), so no test goes through flutter_test's fake HttpClient.
import 'dart:ui' as ui;

import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_image/fespalier_image.dart';
import 'package:fespalier_image/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/images.dart';

/// The override of `imageCdnProvider` that loads the shop's photos through [fakes] (a pending one
/// of its own by default: the photo's placeholder, the product's initial, stays).
Override fakeImages([FakeImages? fakes]) => imageCdnProvider.overrideWithValue(
      (fakes ?? FakeImages()).cdn(shopImages),
    );

/// An image to give `FakeImages(image:)` so that photos show at once (`setUpAll`).
Future<ui.Image> makePhoto() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  return createTestImage(width: 8, height: 8);
}
