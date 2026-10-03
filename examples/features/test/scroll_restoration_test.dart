// `scroll_restoration: true` in pubspec.yaml: the browser's back and forward bring a page's
// scroll offsets back, a `go` to the page starts at the top, and only a scrollable under a
// `PageStorageKey` is restored. `/feed` has two of them: a horizontal list and a vertical one.
import 'package:features/app.g.dart';
import 'package:features/app/feed/page.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The browser's history as far as the app can tell: what it reported to the platform for each
/// location, which the browser keeps for the entry and hands back with back and forward.
class Browser {
  Browser(WidgetTester tester) : _tester = tester {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.navigation,
      (call) async {
        if (call.method == 'routeInformationUpdated') {
          final args = call.arguments as Map<Object?, Object?>;
          _entries.add((uri: args['uri']! as String, state: args['state']));
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.navigation, null),
    );
  }

  final WidgetTester _tester;
  final List<({String uri, Object? state})> _entries = [];

  /// The back or forward button: the engine tells the app the location of the entry it moved
  /// to, with the state the app saved for it (`pushRouteInformation`).
  Future<void> goesTo(String location) async {
    final saved = _entries.lastWhere((e) => e.uri == location);
    await _tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(
        MethodCall('pushRouteInformation', {
          'location': saved.uri,
          'state': saved.state,
        }),
      ),
      (_) {},
    );
    await _tester.pump();
    await _tester
        .pump(const Duration(milliseconds: 400)); // the page transition
    await _tester.pumpAndSettle();
  }
}

Future<Browser> boot(WidgetTester tester, String location) async {
  final browser = Browser(tester);
  await pumpRouter(tester, AppRoutes.router(initialLocation: location));
  return browser;
}

const featured = PageStorageKey<String>('featured');
const feed = PageStorageKey<String>('feed');

/// The scroll offset of the list under [key].
double offset(WidgetTester tester, Key key) => tester
    .state<ScrollableState>(
      find.descendant(of: find.byKey(key), matching: find.byType(Scrollable)),
    )
    .position
    .pixels;

/// Drags the list under [key] by [by] logical pixels along its axis and returns where it is.
Future<double> scroll(WidgetTester tester, Key key, double by) async {
  final horizontal = tester.widget<ListView>(find.byKey(key)).scrollDirection ==
      Axis.horizontal;
  await tester.drag(
    find.byKey(key),
    horizontal ? Offset(-by, 0) : Offset(0, -by),
  );
  await tester.pumpAndSettle();
  return offset(tester, key);
}

void main() {
  testWidgets('back restores the offset the page was left at', (tester) async {
    final browser = await boot(tester, '/feed');
    final scrolled = await scroll(tester, feed, 900);
    expect(scrolled, greaterThan(0));

    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/search');
    expect(find.byType(FeedPage), findsNothing);

    await browser.goesTo('/feed');
    expect(currentLocation(tester), '/feed');
    expect(offset(tester, feed), scrolled);
  });

  testWidgets('forward restores too', (tester) async {
    final browser = await boot(tester, '/feed');
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    await browser.goesTo('/feed');
    final scrolled = await scroll(tester, feed, 700);
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    await browser.goesTo('/feed');
    expect(offset(tester, feed), scrolled);
  });

  testWidgets('a go to the page starts at the top', (tester) async {
    await boot(tester, '/feed');
    await scroll(tester, feed, 900);
    await scroll(tester, featured, 400);

    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    final context = tester.element(find.text('Next'));
    const FeedRoute().go(context);
    await tester.pumpAndSettle();

    expect(find.byType(FeedPage), findsOneWidget);
    expect(offset(tester, feed), 0);
    expect(offset(tester, featured), 0);
    expect(find.text('Item 0'), findsOneWidget);
  });

  testWidgets('two lists on a page do not swap offsets', (tester) async {
    final browser = await boot(tester, '/feed');
    final vertical = await scroll(tester, feed, 900);
    final horizontal = await scroll(tester, featured, 300);
    expect(vertical, isNot(horizontal));

    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    await browser.goesTo('/feed');

    expect(offset(tester, feed), vertical);
    expect(offset(tester, featured), horizontal);
  });
}
