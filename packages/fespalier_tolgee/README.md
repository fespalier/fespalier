# fespalier_tolgee

Translations for [fespalier](https://github.com/fespalier/fespalier) (since 0.10.0): the texts bundled in the app show on
the first frame and offline, [Tolgee](https://tolgee.io)'s Content Delivery brings fresh ones over the air, a cache keeps
them for the next start, and the locale comes from the route (`/fr/produits/2`). fespalier itself has no translation
feature: no file kind, no `fespalier:` key, no `fsp` command, and the generated code is the same bytes.

It does **not** depend on the `tolgee` SDK: that one imports `dart:io` (no web), keeps the locale in a static singleton
and puts the network ahead of `runApp`. This package uses the Tolgee platform (Content Delivery files, ICU messages, the
REST API) and a `TranslationSource` you can replace.

The full guide is [docs/i18n-tolgee.md](https://github.com/fespalier/fespalier/blob/main/docs/i18n-tolgee.md). This page
is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are
the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.9.1
  fespalier_tolgee:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_tolgee
      ref: v0.9.1
```

<!-- x-release-please-end -->

It also needs `flutter_localizations` (for the Material strings of each language) and, to keep the remote texts across
restarts, a `dataCacheStorage` such as `fespalier_storage`'s `PrefsDataStorage`. The package itself uses `http` 1.5 or
newer and `intl` 0.20.2 or newer.

## Wire it

Bundle one `.arb` (or Tolgee JSON) file per language under `assets/i18n/`, list the folder in `flutter: assets:`, and give
the app its setup in `startup()`:

```dart
// lib/app/startup.dart
const _cdn = String.fromEnvironment('TOLGEE_CDN_URL'); // public, not a secret

Future<List<Override>> startup() async => [
  translationsConfig.overrideWithValue(Translations(
    bundled: await BundledTranslations.load(locales: Lang.values.map((l) => l.name)), // local assets only
    baseLocale: 'en',
    remote: _cdn.isEmpty ? null : TolgeeCdn(Uri.parse(_cdn)),
  )),
  dataCacheStorage.overrideWithValue(await PrefsDataStorage.open()),
];

// lib/app/app.dart
MaterialApp.router(
  routerConfig: TranslationScope.routerConfig(
    router,
    localeOf: localeSegment(), // the `$lang` folder: /fr/products
  ),
  supportedLocales: config.supportedLocales.map(localeFromTag),
  localizationsDelegates: GlobalMaterialLocalizations.delegates, // required
)

// anywhere below it
TrText('product.title', args: {'name': product.name})
Text(context.tr('product.stock', {'count': product.stock})) // ICU plural
```

`relocate(uri, to: 'de', routes: AppManifest.all, segment: 0)` respells the current location for a language menu, and
`ref.watch(preferredLocale)` picks the first URL for a root `redirect.dart`.

## Test it

```dart
await pumpRouter(
  tester,
  AppRoutes.router(initialLocation: '/fr/products'),
  app: (router) => App(router: router), // the default app has no TranslationScope
  overrides: fakeTranslations(bundled: {'en': {...}, 'fr': {...}}, remote: FakeTranslations.strict()),
);
```

`fsp test` and `test/routes/setup.dart` need the same `fakeTranslations` overrides and the app's own `app`.
`package:fespalier_tolgee/testing.dart` has `fakeTranslations`, `FakeTranslations` (`set`, `offline`, `notModified`,
`fetchCount`; `.strict()` fails on a missing key), `RecordingEditor` and `MemoryDataStorage`.

## Rules

- **Every read is synchronous and from memory.** A translator is never an `AsyncValue`; the first frame is bundled text
  (or the cache, with a synchronous storage). Nothing here puts the network before `runApp`.
- **No timer, no polling, no microtask, no listener of its own** (`TranslationScope.routerConfig` forwards the Router's own to
  go_router's delegate). A locale is fetched once per `ProviderContainer`, and again on resume or
  reconnect only when `Translations` asks for it. `test/no_timers_test.dart` greps `lib/`.
- **No Tolgee API key in a release build.** `TolgeeCdn` has no parameter for a key. In-context editing is behind
  `kTolgeeInContext` (false in release and profile builds), reads `TOLGEE_API_KEY` from a `--dart-define` in one place and
  never ships; `test/no_secrets_test.dart` greps `lib/`.
- Not built: typed keys, the `tolgee` SDK's widgets, a polling refresh, a `fespalier_adapter.dart`.
