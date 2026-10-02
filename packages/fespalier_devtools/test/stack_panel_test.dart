// The Stack tab: frames, indented, with the layout each shell is and the route each page is.
import 'package:fespalier_devtools/src/ui/chips.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'pump.dart';

/// The left edge of the first widget that shows [text].
double leftOf(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text).first).dx;

void main() {
  testWidgets('shows a layout, with the pages in it indented under it', (
    tester,
  ) async {
    await pumpApp(tester, FakeFespalierClient());
    await openTab(tester, 'Stack');
    expect(find.text('layout layout.dart'), findsOneWidget);
    expect(find.widgetWithText(KindChip, 'shell'), findsOneWidget);
    expect(find.widgetWithText(KindChip, 'page'), findsNWidgets(4));
    expect(
      leftOf(tester, '/catalog'),
      greaterThan(leftOf(tester, 'layout layout.dart')),
    );
  });

  testWidgets('names each page\'s route and file from the tree', (
    tester,
  ) async {
    await pumpApp(tester, FakeFespalierClient());
    await openTab(tester, 'Stack');
    expect(find.text('CatalogRoute'), findsOneWidget);
    expect(find.text('catalog/page.dart'), findsOneWidget);
    expect(find.text('ProductDetailRoute'), findsOneWidget);
    expect(find.text('catalog/\$productId/reviews/page.dart'), findsOneWidget);
    // A page's location is shown when it is not its own path template.
    expect(find.text('/catalog/p1'), findsOneWidget);
  });

  testWidgets('labels a layout inside a layout by its own file', (
    tester,
  ) async {
    await pumpApp(
      tester,
      FakeFespalierClient(snapshot: fixture('snapshot_pushed')),
    );
    await openTab(tester, 'Stack');
    expect(find.text('layout layout.dart'), findsWidgets);
    expect(find.text('layout (account)/layout.dart'), findsOneWidget);
    expect(
      leftOf(tester, 'layout (account)/layout.dart'),
      greaterThan(leftOf(tester, 'layout layout.dart')),
    );
  });

  testWidgets('shows a pushed page with a chip, and what it shows under it', (
    tester,
  ) async {
    await pumpApp(
      tester,
      FakeFespalierClient(snapshot: fixture('snapshot_pushed')),
    );
    await openTab(tester, 'Stack');
    expect(find.widgetWithText(KindChip, 'pushed'), findsOneWidget);
    // The pushed page and the page it shows are the same route.
    expect(find.text('OrderRoute'), findsNWidgets(2));
    // The pushed page has its own stack of pages below it, one level in.
    final pushedLeft = tester
        .getTopLeft(find.widgetWithText(KindChip, 'pushed'))
        .dx;
    expect(pushedLeft, lessThan(leftOf(tester, 'layout layout.dart') + 1));
    expect(find.text('layout layout.dart'), findsNWidgets(2));
  });

  testWidgets('labels a tab layout by its file and the tab the page is in', (
    tester,
  ) async {
    await pumpApp(
      tester,
      FakeFespalierClient(
        snapshot: fixture('snapshot_tabs'),
        tree: golden('tabs'),
      ),
    );
    await openTab(tester, 'Stack');
    expect(find.text('tabs (tabs)/layout.dart · tab 1'), findsOneWidget);
    expect(find.text('SearchRoute'), findsOneWidget);
  });

  testWidgets('shows frames without a tree as they are', (tester) async {
    await pumpApp(
      tester,
      FakeFespalierClient(
        snapshot: fixture('snapshot_catalog'),
        tree: {
          'protocol': 1,
          'package': null,
          'appDir': 'lib/app',
          'items': <Object?>[],
          'sites': <String, Object?>{},
        },
      ),
    );
    await openTab(tester, 'Stack');
    expect(find.text('layout'), findsOneWidget);
    expect(find.text('/catalog/:productId'), findsOneWidget);
    expect(find.text('CatalogRoute'), findsNothing);
  });

  testWidgets('says so when the stack is empty', (tester) async {
    await pumpApp(
      tester,
      FakeFespalierClient(snapshot: fixture('snapshot_not_found')),
    );
    await openTab(tester, 'Stack');
    expect(find.text('The stack is empty.'), findsOneWidget);
  });
}
