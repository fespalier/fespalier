import 'package:fespalier/fespalier.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _bundled = {
  'en': {
    'title': 'Products',
    'count': '{n, plural, one {# item} other {# items}}',
  },
  'fr': {
    'title': 'Produits',
    'count': '{n, plural, one {# article} other {# articles}}',
  },
  'ar': {'title': 'المنتجات'},
};

GoRouter _router(String initial) => GoRouter(
  initialLocation: initial,
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => const Text('root', textDirection: TextDirection.ltr),
    ),
    GoRoute(
      path: '/:lang/x',
      builder: (context, state) => Scaffold(
        body: Column(
          children: [
            TrText('title'),
            Text(context.tr('count', {'n': 2})),
            Text('route:${context.routeLocale}'),
            Text('dir:${Directionality.of(context).name}'),
            Text('loc:${Localizations.localeOf(context).languageCode}'),
            Builder(
              builder: (c) => TextButton(
                onPressed: () => showDialog<void>(
                  context: c,
                  useRootNavigator: true,
                  builder: (_) => AlertDialog(title: TrText('title')),
                ),
                child: const Text('open'),
              ),
            ),
            TextButton(
              onPressed: () => GoRouter.of(context).go('/en/x'),
              child: const Text('to en'),
            ),
          ],
        ),
      ),
    ),
  ],
);

Widget _app(GoRouter router) => ProviderScope(
  overrides: [translationsConfig.overrideWithValue(config(bundled: _bundled))],
  child: MaterialApp.router(
    routerConfig: router,
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('en'), Locale('fr'), Locale('ar')],
    builder: (context, child) => TranslationScope.router(
      router: router,
      localeOf: localeSegment(),
      child: child!,
    ),
  ),
);

void main() {
  testWidgets('/fr/x is French, and Localizations follow', (tester) async {
    final router = _router('/fr/x');
    addTearDown(router.dispose);
    await tester.pumpWidget(_app(router));
    await tester.pumpAndSettle();
    expect(find.text('Produits'), findsOneWidget);
    expect(find.text('2 articles'), findsOneWidget);
    expect(find.text('route:fr'), findsOneWidget);
    expect(find.text('loc:fr'), findsOneWidget);
  });

  testWidgets('/ar/x is RTL', (tester) async {
    final router = _router('/ar/x');
    addTearDown(router.dispose);
    await tester.pumpWidget(_app(router));
    await tester.pumpAndSettle();
    expect(find.text('dir:rtl'), findsOneWidget);
    expect(find.text('المنتجات'), findsOneWidget);
  });

  testWidgets('a root-navigator dialog is translated too', (tester) async {
    final router = _router('/fr/x');
    addTearDown(router.dispose);
    await tester.pumpWidget(_app(router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Produits'), findsNWidgets(2));
  });

  testWidgets('the locale follows the location', (tester) async {
    final router = _router('/fr/x');
    addTearDown(router.dispose);
    await tester.pumpWidget(_app(router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('to en'));
    await tester.pumpAndSettle();
    expect(find.text('Products'), findsOneWidget);
    expect(find.text('route:en'), findsOneWidget);
  });

  testWidgets('a location with no locale keeps the previous one', (
    tester,
  ) async {
    final router = _router('/fr/x');
    addTearDown(router.dispose);
    await tester.pumpWidget(_app(router));
    await tester.pumpAndSettle();
    router.go('/');
    await tester.pumpAndSettle();
    expect(find.text('root'), findsOneWidget);
    // Still French underneath: the scope kept it.
    router.go('/zz/x');
    await tester.pumpAndSettle();
    expect(find.text('route:fr'), findsOneWidget);
  });

  testWidgets('a fixed scope', (tester) async {
    await tester.pumpWidget(
      host(
        overrides: [
          translationsConfig.overrideWithValue(config(bundled: _bundled)),
        ],
        home: Builder(
          builder: (context) =>
              TranslationScope(locale: 'fr', child: TrText('title')),
        ),
      ),
    );
    expect(find.text('Produits'), findsOneWidget);
  });

  testWidgets(
    'context.tr outside a scope is a FlutterError naming TranslationScope',
    (tester) async {
      await tester.pumpWidget(
        host(home: Builder(builder: (context) => Text(context.tr('title')))),
      );
      final error = tester.takeException();
      expect(error, isA<FlutterError>());
      expect(error.toString(), contains('TranslationScope'));
    },
  );
}
