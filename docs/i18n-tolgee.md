# Translations: fespalier_tolgee

`fespalier_tolgee` (since 0.10.0) gives an app translated texts that show at once, keep working offline and can be
updated without a release. The texts bundled in the app are the floor, [Tolgee](https://tolgee.io)'s Content Delivery
(or any server you write a `TranslationSource` for) brings fresh ones, and the language comes from the URL.

fespalier itself has no translation feature: no file kind, no `fespalier:` key, no `fsp` command, and `app.g.dart` is the
same bytes. The package is a companion, installed like `fespalier_flags`.

A taste first, then the details.

```dart
// lib/app/$lang/products/$id/page.dart  ->  /fr/produits/2, /de/produkte/2
class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.product});
  final Product product;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: TrText('product.title', args: {'name': product.name})),
    body: Text(context.tr('product.stock', {'count': product.stock})), // {count, plural, ...}
  );
}
```

Contents: [Install](#install), [Locales and the URL](#locales-and-the-url), [Bundled translations](#bundled-translations),
[Over the air](#over-the-air), [Cache and offline](#cache-and-the-offline-fallback-chain),
[In-context editing](#in-context-editing-debug-only), [Testing](#testing), [Rules](#rules-and-what-it-costs),
[Not built](#not-built).

## What it is, and why not the `tolgee` SDK

The package uses the Tolgee **platform** (Content Delivery files, ICU messages, the REST API, the CLI's pulls), not the
**SDK**. The official `tolgee` package on pub.dev (1.2.0 when this was written) is marked beta, and:

| Fact | Consequence |
| --- | --- |
| It imports `dart:io`; pub.dev lists Android, iOS, Linux, macOS and Windows, not the web. | fespalier is web-first (path URLs): the SDK would break those builds. |
| Its API is one static singleton: `Tolgee.setCurrentLocale` is global and returns a `Future`. | A URL-driven locale must be a synchronous value per route and per `ProviderContainer`; a global leaks between tests. |
| `Tolgee.init` is a `Future` that, with `apiUrl` or `cdnUrl`, can put the network before `runApp`. | The adapter and startup rules say "a local read, never the network". |
| In-context editing runs on the same `init(apiKey:)` as production. | A key could end up in a release build. Tolgee's own docs say never to ship one. |

So fespalier_tolgee reads Tolgee's public Content Delivery files itself (about 60 lines of `package:http`), formats the
ICU messages itself, and keeps a `TranslationSource` interface for anything else.

## Install

Same `url` and same `ref` as fespalier: pub resolves the two to one package only then.

```yaml
dependencies:
  flutter_localizations: { sdk: flutter }
  fespalier:         { git: { url: https://github.com/fespalier/fespalier, path: packages/fespalier,         ref: v0.9.1 } }
  fespalier_tolgee:  { git: { url: https://github.com/fespalier/fespalier, path: packages/fespalier_tolgee,  ref: v0.9.1 } }
  fespalier_storage: { git: { url: https://github.com/fespalier/fespalier, path: packages/fespalier_storage, ref: v0.9.1 } } # optional: the cache survives restarts
flutter:
  assets: [assets/i18n/]
```

(Use the release tag that has the package, 0.10.0 or later; the snippet shows the tag of the other companions.)

## Locales and the URL

The locale is part of the route, so a link, a refresh and a deep link all show the same language. Two folder features
give it; use either or both.

**A `$lang` segment** gives a locale to every URL. Make it an enum, so `/xx/products` is not found:

```dart
// lib/lang.dart
enum Lang { en, fr, de }
// lib/app/$lang/products/$id/page.dart  ->  /:lang/products/:id
```

**Localized spellings** (`const paths = {'fr': 'produits', 'de': 'produkte'};` in a `route.dart`) give
`/fr/produits/2`. Note that spellings alone say nothing about a canonical path or a spelling two languages share: the
locale is then the previous one, or the device's.

### The scope

Put `TranslationScope.router` in `MaterialApp.router`'s `builder`, so pages on the root navigator (dialogs, `present.dart`)
are under it too:

```dart
MaterialApp.router(
  routerConfig: router,
  supportedLocales: config.supportedLocales.map(localeFromTag), // from translationsConfig
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => TranslationScope.router(
    router: router,
    localeOf: localeSegment(), // or firstLocaleOf([localeSegment(), localeSpelling(AppManifest.all)])
    child: child!,
  ),
)
```

On each location change the locale is `localeOf(uri)` resolved against what you bundled (`fr-CA` becomes `fr`), else the
previous one, else `preferredLocale`. The scope also sets `Localizations.override`, so Material strings and the text
direction follow: an `ar` route is right to left. Pass `supportedLocales` as above, or Flutter prints a warning for a
bundled locale a delegate does not support.

### Reading it

- `context.tr('key', {'name': x})` and `TrText('key')` read the scope's translator. `context.routeLocale` is the tag.
- A `data.dart` takes the locale as the typed segment (`required Lang lang`), not from a global.
- A language menu: `context.go(relocate(GoRouterState.of(context).uri, to: 'de', routes: AppManifest.all, segment: 0))`
  respells each localized level (`/fr/produits/2?q=1` becomes `/de/produkte/2?q=1`).
- The first URL: a root `redirect.dart` returns `HomeRoute(lang: Lang.values.byName(ref.read(preferredLocale))).location`.
  `preferredLocale` is the device's first supported locale; override the provider with the user's own setting.

## Bundled translations

One file per language, shipped as assets: the first launch, offline included, shows them.

```json
// assets/i18n/fr.arb
{
  "@@locale": "fr",
  "product.title": "{name}",
  "product.stock": "{count, plural, =0 {Épuisé} one {# en stock} other {# en stock}}"
}
```

`BundledTranslations.load(locales: [...])` reads `assets/i18n/{locale}.arb` (a path ending in `.arb` is ARB, anything else is
Tolgee JSON, nested or flat) from `rootBundle`. A missing file throws, so `startup()` fails and your `splash.dart` offers
the retry. Fill the folder with `tolgee pull` or a manual export from Tolgee, optionally as a `before:` step of a `tasks:`
entry in the pubspec.

The supported messages are the ARB subset of ICU: `{name}`, `plural` (with `=0`, `zero`, `one`, `two`, `few`, `many`,
`other`, `offset:` and `#`), `select`, `selectordinal` (read like plural) and `'` quoting. Plural categories come from
`intl`, so French treats 0 as `one`. Tolgee's ARB export does not replace `#`, so it repeats the placeholder
(`{count, plural, one {{count} dog} other {{count} dogs}}`): both forms work. A malformed message is shown as written and
reported once in debug.

## Over the air

Create a Content Delivery in Tolgee (Project settings), pick **JSON** or **ARB**, flat or nested, and copy its URL.

```dart
const _cdn = String.fromEnvironment('TOLGEE_CDN_URL'); // public, not a secret
remote: _cdn.isEmpty ? null : TolgeeCdn(Uri.parse(_cdn)), // TolgeeCdn(uri, format: TolgeeCdnFormat.arb, namespace: 'app')
```

Tolgee publishes after a change with a delay of up to 15 minutes. The package asks for `<url>/<locale>.json` (or `.arb`,
or `<namespace>/<locale>.json`; `file:` overrides the name) when a locale is first used in a container, with
`If-None-Match` when it has an ETag. A 304 or a 404 changes nothing; any failure keeps what the app has.

- Never on a timer. `Translations(refreshOnResume: true)` asks again when the app resumes, `refreshOnReconnect` (on by
  default) once the network is back **after a failed fetch**, both through fespalier's `appResumeSignal` and
  `reconnectSignal` (`fespalier_connectivity` fires the second).
- The web needs the CDN to answer with CORS headers. If it does not, a web app keeps working on bundled and cached texts.

## Cache and the offline fallback chain

A key is looked up in this order, and the first catalog that has it wins:

1. edited in the in-context panel (debug builds only),
2. the remote catalog fetched in this run, or the cached one,
3. the bundled one,

each for the locale (`fr-CA`), then its language (`fr`), then the base locale, then the key itself. `Translator.originOf(key)`
says which link answered.

Remote catalogs are saved in fespalier's `dataCacheStorage` under `fespalier_tolgee:<tag>` for `cacheMaxAge` (30 days by
default). A synchronous storage (`fespalier_storage`'s `PrefsDataStorage`) has them on the first frame; Hive's arrives a
frame later. The storage's size budget may evict an entry written long ago: that is harmless, the chain falls back to the
bundled text. A first launch offline shows bundled text, with no error and no pending timer.

## In-context editing (debug only)

Click a text in the running app, edit it, and see it at once. It is compiled in only when both hold: a debug build, and
`--dart-define=fespalier_tolgee.in_context=true` (`kTolgeeInContext` in `package:fespalier_tolgee/in_context.dart`).

```
flutter run --dart-define-from-file=tolgee.local.json
```

`tolgee.local.json` is gitignored and holds `{"fespalier_tolgee.in_context": "true", "TOLGEE_API_KEY": "tgpak_..."}`. Give
the key only the scopes you need (translations.edit). **Never pass the key to `flutter build`:** a key in a build is
public. Release builds pass only `TOLGEE_CDN_URL`; in release and profile builds `kTolgeeInContext` is a `const false`, so the
panel, the editor and the key's `String.fromEnvironment` are compiled out.

A small handle opens a panel with the keys read on the current screen, their value and their origin. A save calls
`PUT /v2/projects/translations` with `X-API-Key` and puts the text into the edited layer at once, so you do not wait for
the CDN. Everyone else sees it when Tolgee publishes. Without a key the panel is read only.

## Testing

```dart
await pumpRouter(
  tester,
  AppRoutes.router(initialLocation: '/fr/products'),
  overrides: fakeTranslations(
    bundled: {'en': {'title': 'Products'}, 'fr': {'title': 'Produits'}},
    remote: FakeTranslations.strict(), // a key nobody has fails the test
  ),
);
```

- `FakeTranslations` is an in-memory source with no delay: `set(locale, messages)`, `offline()`, `notModified()`,
  `fetchCount(locale)`. A fetch lands on the next `pump`.
- A restart: share one `MemoryDataStorage` (`dataCacheStorage.overrideWithValue`) between two `pumpRouter` calls.
- `fsp test` and `test/routes/setup.dart`: return `fakeTranslations(...)` from `overrides(pattern)`.
- `RecordingEditor` records what the in-context panel saves.

## Rules and what it costs

- Every read is synchronous and from memory; a translator is never an `AsyncValue`.
- No timer, no polling, no listener: `test/no_timers_test.dart` greps `lib/`.
- No API key in a release build, and `TolgeeCdn` has no parameter for one: `test/no_secrets_test.dart` greps `lib/`.
- No telemetry in v1. A future `TelemetryOp` would go through `FespalierTelemetry.begin` and `finish` and never carry keys,
  texts or the CDN URL.
- It adds `http` and `intl` and nothing else beyond fespalier. It is in the Flutter 3.32 `floor` job.

## Not built

Typed keys (reading assets at build time is `gen-l10n`'s job, and `app.g.dart` must depend on `lib/app` and the pubspec
alone; an app may keep `gen-l10n` beside this, its getters are just not updated over the air), the `tolgee` SDK's widgets,
a polling refresh, and a `fespalier_adapter.dart` entry (the bundled texts are an async asset read and the setup is app
code, which `startup()` already does).
