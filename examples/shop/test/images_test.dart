// Product photos through an image CDN (since 0.9.0): the list asks for each photo at the size of
// its row, hovering a row warms the photo at the size its page shows, and that photo flies to the
// page with no download of its own. `FakeImages` stands in for the network.
import 'dart:ui' as ui;

import 'package:fespalier/testing.dart';
import 'package:fespalier_image/testing.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/app.g.dart';

import 'images.dart';

/// `https://images.example.com/products/<id>.jpg`, URL-safe base64 without padding.
const encoded = {
  1: 'aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcHJvZHVjdHMvMS5qcGc',
  2: 'aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcHJvZHVjdHMvMi5qcGc',
  3: 'aHR0cHM6Ly9pbWFnZXMuZXhhbXBsZS5jb20vcHJvZHVjdHMvMy5qcGc',
};

/// The EmgR URL of product [id]'s photo, square, [width] pixels wide.
String photo(int id, int width) =>
    'http://localhost:13001/unsigned/rs:fill:$width:$width/${encoded[id]}.webp';

late ui.Image image;

Future<void> boot(WidgetTester tester, FakeImages fakes) async {
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/products'),
    overrides: [fakeImages(fakes)],
  );
  // data.dart is slow on purpose (a timer, not a frame): wait it out.
  await tester.pump(const Duration(seconds: 1));
}

Future<TestGesture> hover(WidgetTester tester, Finder row) async {
  final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await pointer.addPointer(location: Offset.zero);
  addTearDown(pointer.removePointer);
  await pointer.moveTo(tester.getCenter(row));
  await tester.pump();
  return pointer;
}

void main() {
  setUpAll(() async => image = await makePhoto());

  testWidgets('the list asks for each photo at the bucket its row needs', (
    tester,
  ) async {
    final fakes = FakeImages();
    await boot(tester, fakes);
    // A 40-point photo at 3x is 120 pixels: the 128 bucket, square (aspectRatio: 1).
    expect(fakes.requested, [photo(1, 128), photo(2, 128), photo(3, 128)]);
    // The photos have not arrived: each row shows the product's initial.
    expect(find.text('P'), findsOneWidget);
    expect(find.text('C'), findsNWidgets(2));
  });

  testWidgets('a photo that fails leaves the initial, with no error', (
    tester,
  ) async {
    final fakes = FakeImages();
    await boot(tester, fakes);
    fakes.fail(photo(3, 128));
    await tester.pump();
    expect(find.text('P'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hovering a row warms the photo its page shows, not the row\'s', (
    tester,
  ) async {
    final fakes = FakeImages();
    await boot(tester, fakes);
    await hover(tester, find.text('Pour-over kettle'));
    // The page's photo is 160 points wide: 480 pixels, the 640 bucket.
    expect(fakes.requested, [
      photo(1, 128),
      photo(2, 128),
      photo(3, 128),
      photo(3, 640),
    ]);
    // The product's data was started too: let FakeApi's timer fire.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the photo flies with no request, and the page has it at once', (
    tester,
  ) async {
    final fakes = FakeImages(image: image);
    await boot(tester, fakes);
    final pointer = await hover(tester, find.text('Pour-over kettle'));
    // The product's data arrives (500 ms), so its page is in the first frame of the transition.
    await tester.pump(const Duration(seconds: 1));
    final asked = [...fakes.requested];
    expect(asked, contains(photo(3, 640)));

    await pointer.down(tester.getCenter(find.text('Pour-over kettle')));
    await pointer.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // In flight: no download, the page's photo and the shuttle come from the cache.
    expect(fakes.requested, asked);

    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/products/3');
    expect(fakes.requested, asked);
    final page = findRoutePage('/products/:id');
    expect(
      find.descendant(
        of: page,
        matching: find.byWidgetPredicate(
          (w) => w is Image && w.image == fakes.provider(photo(3, 640)),
        ),
      ),
      findsOneWidget,
    );
    // The placeholder, the product's initial, is gone.
    expect(find.descendant(of: page, matching: find.text('P')), findsNothing);
  });
}
