import 'dart:async';

import 'package:fespalier/fespalier.dart'
    show ProviderScope, RouteHero, RouteHeroes, TypedLocation;
import 'package:fespalier_image/fespalier_image.dart';
import 'package:fespalier_image/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final class _Loc extends TypedLocation {
  const _Loc();

  @override
  String get location => '/products/3';
}

/// A list with a [listSize] thumbnail that opens a page with a [pageSize] photo of the same
/// picture, in the shape [pageRatio]. Both photos measure their box (no `width:`), the way a
/// photo in a layout does. [precache] warms the page's size before the push, as
/// `RouteLink(onPreload:)` does.
Widget heroApp(
  FakeImages fakes, {
  required bool shuttle,
  double listSize = 40,
  double pageSize = 160,
  double pageRatio = 1,
  bool precache = false,
}) {
  Widget photo(double size, double ratio) => SizedBox(
    width: size,
    child: Hero(
      tag: 'p',
      flightShuttleBuilder: shuttle ? ResponsiveImage.flightShuttle : null,
      child: ResponsiveImage(
        'products/3.jpg',
        aspectRatio: ratio,
        placeholder: testPlaceholder,
      ),
    ),
  );
  return ProviderScope(
    overrides: [imageCdnProvider.overrideWithValue(fakes.cdn(emgr))],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Align(
            alignment: Alignment.topLeft,
            child: GestureDetector(
              key: const Key('open'),
              onTap: () {
                if (precache) {
                  unawaited(
                    ResponsiveImage.precache(
                      context,
                      'products/3.jpg',
                      width: pageSize,
                      aspectRatio: pageRatio,
                    ),
                  );
                }
                unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        body: Align(
                          alignment: Alignment.topLeft,
                          child: GestureDetector(
                            key: const Key('back'),
                            onTap: () => Navigator.of(context).pop(),
                            child: photo(pageSize, pageRatio),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
              child: photo(listSize, 1),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(makeTestImage);
  setUp(resetImageState);

  /// The `Image` widgets showing [url] of [fakes].
  Finder showing(FakeImages fakes, String url) => find.byWidgetPredicate(
    (w) => w is Image && w.image == fakes.provider(url),
  );

  final thumb = productUrl(128, height: 128);
  final large = productUrl(640, height: 640);

  testWidgets(
    'with the page\'s size precached, the flight shows it and asks for nothing',
    (tester) async {
      final fakes = FakeImages(image: testImage);
      await tester.pumpWidget(heroApp(fakes, shuttle: true, precache: true));
      expect(fakes.requested, [thumb]);

      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
      // The precache asked once; the page's own image, built offstage at the start of the flight,
      // found it in the cache.
      expect(fakes.requested, [thumb, large]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(fakes.requested, [thumb, large]);
      // The shuttle shows the widest variant that is loaded, at every size of the flight.
      expect(showing(fakes, large), findsOneWidget);
      expect(showing(fakes, thumb), findsNothing);
      expect(placeholder, findsNothing);

      await tester.pumpAndSettle();
      expect(fakes.requested, [thumb, large]);
      expect(showing(fakes, large), findsOneWidget);
      expect(placeholder, findsNothing);
    },
  );

  testWidgets(
    'without a precache, the thumbnail flies and stands in until the page\'s image arrives',
    (tester) async {
      final fakes = FakeImages();
      await tester.pumpWidget(heroApp(fakes, shuttle: true));
      fakes.complete(thumb, testImage);
      await tester.pump();

      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
      // The page asked for its own size once, as soon as it was laid out.
      expect(fakes.requested, [thumb, large]);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(fakes.requested, [thumb, large]);
      expect(showing(fakes, thumb), findsWidgets);
      expect(placeholder, findsNothing);

      await tester.pumpAndSettle();
      // Never blank: the page shows the thumbnail until its own image arrives.
      expect(fakes.requested, [thumb, large]);
      expect(fakes.isPending(large), isTrue);
      expect(showing(fakes, thumb), findsOneWidget);
      expect(placeholder, findsNothing);

      fakes.complete(large, testImage);
      await tester.pump();
      expect(showing(fakes, large), findsOneWidget);
    },
  );

  testWidgets('a pop flies the page\'s image, in any shape, and starts no load', (
    tester,
  ) async {
    final fakes = FakeImages(image: testImage);
    // The page is 4:3, the list square: the list's own image never had the 640 square.
    await tester.pumpWidget(heroApp(fakes, shuttle: true, pageRatio: 4 / 3));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    final page = productUrl(640, height: 480);
    expect(fakes.requested, [thumb, page]);

    await tester.tap(find.byKey(const Key('back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(fakes.requested, [thumb, page]);
    expect(showing(fakes, page), findsOneWidget);
    await tester.pumpAndSettle();
    expect(fakes.requested, [thumb, page]);
  });

  testWidgets(
    'with the flight shuttle a push asks for exactly the page\'s URL',
    (tester) async {
      final fakes = FakeImages(image: testImage);
      await tester.pumpWidget(heroApp(fakes, shuttle: true, pageRatio: 4 / 3));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 75));
      }
      await tester.pumpAndSettle();
      expect(fakes.requested, [thumb, productUrl(640, height: 480)]);
    },
  );

  testWidgets(
    'control: Flutter\'s own shuttle sizes itself to the flight and asks for a URL nobody needs',
    (tester) async {
      final fakes = FakeImages(image: testImage);
      await tester.pumpWidget(heroApp(fakes, shuttle: false, pageRatio: 4 / 3));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
      final page = productUrl(640, height: 480);
      expect(fakes.requested, [thumb, page]);
      await tester.pump(const Duration(milliseconds: 100));
      // The image rebuilt in the overlay measures the rectangle of the flight at its first
      // layout, and downloads a bucket for it: one more URL than the thumbnail and the page
      // (README, "Images in heroes"). With the flight shuttle there is none.
      expect(fakes.requested.length, greaterThan(2));
      await tester.pumpAndSettle();
    },
  );

  test('imageHero is route.hero with ResponsiveImage.flightShuttle', () {
    const child = SizedBox();
    final hero = const _Loc().imageHero(
      'photo',
      child: child,
      onBackGesture: true,
    );
    expect(hero, isA<RouteHero>());
    final routeHero = hero as RouteHero;
    expect(routeHero.shuttle, ResponsiveImage.flightShuttle);
    expect(routeHero.child, same(child));
    expect(routeHero.onBackGesture, isTrue);
    expect(routeHero.tag, const _Loc().heroTag('photo'));
  });

  testWidgets('ResponsiveImageFlight marks what is below it', (tester) async {
    late bool inside;
    late bool outside;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          outside = ResponsiveImageFlight.of(context);
          return ResponsiveImageFlight(
            child: Builder(
              builder: (context) {
                inside = ResponsiveImageFlight.of(context);
                return const SizedBox();
              },
            ),
          );
        },
      ),
    );
    expect(outside, isFalse);
    expect(inside, isTrue);
  });
}
