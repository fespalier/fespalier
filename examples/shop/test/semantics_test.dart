// `semantics_ids: true` in pubspec.yaml: each page's own widget wears
// `Semantics(identifier: 'route:<pattern>')`, which is what Maestro's `id:` selector matches
// (see .maestro/routes/). It is in the tree when the route's page is built, not while a loading
// or a not-found view shows, and not for a page underneath. It marks the page and nothing else: the
// text a page draws outside a scroll view keeps its own semantics nodes, so a screen reader reads
// it one line at a time and not as one block.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/app.g.dart';
import 'images.dart';

Future<void> boot(WidgetTester tester, String location) async {
  final container = ProviderContainer(overrides: [fakeImages()]);
  addTearDown(container.dispose);
  // /checkout and /products/:id are deferred routes (`const deferred = true;`): their code loads
  // on the real event loop, which a widget test's pumps never run, so load it first.
  await tester.runAsync(AppRoutes.loadDeferred);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: AppRoutes.router(initialLocation: location),
      ),
    ),
  );
}

/// The `Semantics` widgets with this identifier, whether or not the semantics tree is on.
Finder wearing(String id) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.identifier == id,
    );

void main() {
  testWidgets('the home page wears route:/', (tester) async {
    final handle = tester.ensureSemantics();
    await boot(tester, '/');
    expect(wearing('route:/'), findsOneWidget);
    expect(find.bySemanticsIdentifier('route:/'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a data page wears it once its data is there, not while loading',
      (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await boot(tester, '/products/1');
    await tester.pump();
    // loading.dart is showing: the page is not built, so there is no identifier yet.
    expect(find.bySemanticsIdentifier('route:/products/:id'), findsNothing);
    expect(wearing('route:/products/:id'), findsNothing);

    // FakeApi answers after 700 ms, on a timer: pumpAndSettle would not wait for it.
    await tester.pump(const Duration(seconds: 1));
    expect(find.bySemanticsIdentifier('route:/products/:id'), findsOneWidget);
    // The /products page below it is not on screen: it has no identifier on screen either.
    expect(find.bySemanticsIdentifier('route:/products'), findsNothing);
    handle.dispose();
  });

  testWidgets('a segment that does not parse shows not_found, which has none', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await boot(tester, '/products/abc');
    await tester.pump();
    expect(find.text('Nothing at /products/abc'), findsOneWidget);
    expect(find.bySemanticsIdentifier('route:/products/:id'), findsNothing);
    // go_router still builds the /products page underneath; let it load.
    await tester.pump(const Duration(seconds: 1));
    handle.dispose();
  });

  testWidgets('a page with a segment wears the pattern, not the value', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await boot(tester, '/greet/Ada');
    await tester.pumpAndSettle();
    expect(find.text('Hello, Ada'), findsOneWidget);
    expect(find.bySemanticsIdentifier('route:/greet/:name'), findsOneWidget);
    expect(find.bySemanticsIdentifier('route:/greet/Ada'), findsNothing);
    handle.dispose();
  });

  testWidgets(
      'the identifier node has no label: the text of a page keeps its own nodes',
      (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await boot(tester, '/products/1');
    await tester.pump(const Duration(seconds: 1));

    // The product page draws its name and price in a Column, outside any scroll view. Both are
    // plain `Text`, with no semantics node of their own unless the wrapper above them asks for one.
    final page = tester.getSemantics(
      find.bySemanticsIdentifier('route:/products/:id'),
    );
    expect(page.identifier, 'route:/products/:id');
    // What `fsp test` looks for is the widget, and Maestro the node: both are still there.
    expect(findRoutePage('/products/:id'), findsOneWidget);
    expect(page.label, isEmpty,
        reason: 'the page node must not read its children out as one block');

    for (final text in ['Coffee beans, 500 g', '€9.50']) {
      final node = tester.getSemantics(find.text(text));
      expect(node.id, isNot(page.id),
          reason: '"$text" is merged into the page node');
      expect(node.label, text);
      expect(node.identifier, isEmpty);
    }
    handle.dispose();
  });

  testWidgets(
      'a page with one line of text still has a label-free identifier node', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await boot(tester, '/greet/Ada');
    await tester.pumpAndSettle();

    final page = tester.getSemantics(
      find.bySemanticsIdentifier('route:/greet/:name'),
    );
    expect(page.label, isEmpty);
    final line = tester.getSemantics(find.text('Hello, Ada'));
    expect(line.id, isNot(page.id));
    expect(line.label, 'Hello, Ada');
    handle.dispose();
  });
}
