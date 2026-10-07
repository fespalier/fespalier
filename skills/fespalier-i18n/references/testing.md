# Testing translated routes

Since 0.10.0 (`package:fespalier_tolgee/testing.dart`). This page lives in `fespalier-i18n`, not in
`fespalier-testing`'s recipes, because it needs a `$lang` folder at the root of its own scratch app. The general
rules (`pumpRouter`, deep links, pending timers) are in [`fespalier-testing`](../../fespalier-testing/SKILL.md).

## The one rule: pass your app

`pumpRouter`'s default app is a bare `MaterialApp.router(routerConfig: router)`: **no `TranslationScope`**, so
`context.tr` throws `No TranslationScope found above this widget.` Pass the app that uses
`TranslationScope.routerConfig`: `app: (router) => App(router: router)` (or the generated `AppMain.app`). And override
`translationsConfig`, which `startup()` sets and `pumpRouter` does not run: `fakeTranslations(...)` does it.

The app under test:

```dart
// lib/lang.dart
enum Lang { en, fr }
```

```dart
// lib/app/app.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class App extends ConsumerWidget {
  const App({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    routerConfig: TranslationScope.routerConfig(router, localeOf: localeSegment()),
    supportedLocales: ref.watch(translationsConfig).supportedLocales.map(localeFromTag),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
  );
}
```

```dart
// lib/app/$lang/products/page.dart
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter/material.dart';
import 'package:my_app/lang.dart';

class ProductsPage extends StatelessWidget {
  const ProductsPage({super.key, required this.lang});

  final Lang lang;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const TrText('products.title')),
    body: Center(child: Text(context.tr('product.stock', {'count': 3}))),
  );
}
```

```yaml
# pubspec.yaml dependencies
  flutter_localizations:
    sdk: flutter
```

## The tests

```dart
// test/i18n_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_tolgee/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/app/app.dart';

const bundled = {
  'en': {'products.title': 'Products', 'product.stock': '{count, plural, =0 {Sold out} other {# in stock}}'},
  'fr': {'products.title': 'Produits', 'product.stock': '{count, plural, =0 {Épuisé} other {# en stock}}'},
};

Future<void> open(WidgetTester tester, String location, List<Override> overrides) => pumpRouter(
  tester,
  // A new router for every test: a router remembers where it went, and the scope's config is made once per router.
  AppRoutes.router(initialLocation: location),
  app: (router) => App(router: router),
  overrides: overrides,
);

void main() {
  testWidgets('the route chooses the language', (tester) async {
    await open(tester, '/fr/products', fakeTranslations(bundled: bundled, remote: FakeTranslations.strict()));
    expect(find.text('Produits'), findsOneWidget);
    expect(find.text('3 en stock'), findsOneWidget);
  });

  testWidgets('a fetched text replaces the bundled one on the next pump', (tester) async {
    final remote = FakeTranslations.strict()..set('fr', {'products.title': 'Nos produits', 'product.stock': '{count} dispo'});
    await open(tester, '/fr/products', fakeTranslations(bundled: bundled, remote: remote));
    await tester.pump(); // a fetch lands on the next pump
    expect(find.text('Nos produits'), findsOneWidget);
    expect(remote.fetchCount('fr'), 1);
  });

  testWidgets('offline, the bundled text stays', (tester) async {
    final remote = FakeTranslations.strict()..offline();
    await open(tester, '/fr/products', fakeTranslations(bundled: bundled, remote: remote));
    await tester.pump();
    expect(find.text('Produits'), findsOneWidget);
  });

  testWidgets('a restart shows the cached text before the network answers', (tester) async {
    final storage = MemoryDataStorage();
    final first = FakeTranslations.strict()..set('fr', {'products.title': 'Nos produits', 'product.stock': '{count} dispo'});
    await open(tester, '/fr/products', [
      ...fakeTranslations(bundled: bundled, remote: first),
      dataCacheStorage.overrideWithValue(storage),
    ]);
    await tester.pump();
    expect(find.text('Nos produits'), findsOneWidget);

    // The next start: the same storage, a source that is offline.
    final second = FakeTranslations.strict()..offline();
    await open(tester, '/fr/products', [
      ...fakeTranslations(bundled: bundled, remote: second),
      dataCacheStorage.overrideWithValue(storage),
    ]);
    await tester.pump();
    expect(find.text('Nos produits'), findsOneWidget);
  });
}
```

- **`fakeTranslations({bundled, base = 'en', remote, strict = false, cacheMaxAge})`** returns the overrides (the
  `translationsConfig`). `bundled` is plain maps (`BundledTranslations.fromMaps`): no assets are read in a test, so
  nothing in `pubspec.yaml`'s `flutter: assets:` is needed there.
- **`FakeTranslations`** is an in-memory `TranslationSource` with no delay: `set(locale, messages)`, `offline()`
  (throws as a failed fetch), `notModified()` (answers null, a 304), `online()` (undoes both), `fetchCount(locale)`.
  It is all `Future.value`, so it leaves no timer pending.
- **Strict.** `FakeTranslations.strict()` (or `fakeTranslations(strict: true)`) turns every key `tr` cannot find into a
  `FlutterError.reportError`, so a typo fails the test with
  `No translation for "<key>" in <locale> or its fallbacks`. Use it by default.
- **A restart** is the same `MemoryDataStorage` as `dataCacheStorage` in two `pumpRouter` calls.
- A **malformed message** (a bad ICU string in a catalog) is reported through `FlutterError.reportError` in debug, so a
  `testWidgets` fails on it as well.
- `RecordingEditor` (`translationEditor.overrideWithValue(RecordingEditor())`) records what the in-context panel
  saves: [`in-context-editing.md`](in-context-editing.md).

## `fsp test` and `setup.dart`

`fsp test` writes `test/routes/routes_test.dart` and boots each route with `setup.dart`'s overrides. Two things are
needed, as above: return `fakeTranslations(...)` from `overrides(pattern)`, and give the app's own `app` (a smoke
test through the default app has no scope, and `context.tr` throws). A `$lang` route is a dynamic route, so it needs a
sample in `test.samples` (`/en/products`), or it is skipped.

```dart
// setup.dart, in test/routes/ (a fragment: App is your own widget)
import 'package:fespalier/testing.dart';
import 'package:fespalier_tolgee/testing.dart';

List<Override> overrides(String pattern) => fakeTranslations(
  bundled: {'en': {'products.title': 'Products'}},
  remote: FakeTranslations.strict(),
);

Widget app(GoRouter router) => App(router: router);
```

See [`route-smoke-tests.md`](../../fespalier-testing/references/route-smoke-tests.md).

## Where the code is

`packages/fespalier_tolgee/lib/testing.dart` (`FakeTranslations`, `fakeTranslations`, `RecordingEditor`) and the
package's own `test/` (a `testWidgets` per behaviour above).
