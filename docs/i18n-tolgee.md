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

| Fact                                                                                              | Consequence                                                                                                          |
| ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| It imports `dart:io`; pub.dev lists Android, iOS, Linux, macOS and Windows, not the web.          | fespalier is web-first (path URLs): the SDK would break those builds.                                                |
| Its API is one static singleton: `Tolgee.setCurrentLocale` is global and returns a `Future`.      | A URL-driven locale must be a synchronous value per route and per `ProviderContainer`; a global leaks between tests. |
| `Tolgee.init` is a `Future` that, with `apiUrl` or `cdnUrl`, can put the network before `runApp`. | The adapter and startup rules say "a local read, never the network".                                                 |
| In-context editing runs on the same `init(apiKey:)` as production.                                | A key could end up in a release build. Tolgee's own docs say never to ship one.                                      |

So fespalier_tolgee reads Tolgee's public Content Delivery files itself (about 60 lines of `package:http`), formats the
ICU messages itself, and keeps a `TranslationSource` interface for anything else.

## Install

Add the package next to fespalier with the **same `url` and the same `ref`**: pub resolves the two to one package only
then. The tag must be a release that contains the package (0.10.0 or later). The install block, with the version
release-please keeps current, is in [the package's README](../packages/fespalier_tolgee/README.md#install).

You also need `flutter_localizations` in your dependencies and `assets: [assets/i18n/]` under `flutter:`; for a cache that
survives restarts, `fespalier_storage` (`PrefsDataStorage`).

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

Give `MaterialApp.router` the config `TranslationScope.routerConfig` makes from your router, instead of the router itself.
It is go_router's own config with the root Navigator wrapped in the scope, built inside the Router's own build, so the very
first frame is in the route's language (a redirect included), a location change updates it in the same frame, and pages on
the root navigator (dialogs, `present.dart`) are under it too. It adds no listener of its own.

```dart
MaterialApp.router(
  routerConfig: TranslationScope.routerConfig(
    router,
    localeOf: localeSegment(), // or firstLocaleOf([localeSegment(), localeSpelling(AppManifest.all)])
  ),
  supportedLocales: config.supportedLocales.map(localeFromTag), // from translationsConfig
  localizationsDelegates: GlobalMaterialLocalizations.delegates, // required, see below
)
```

On each location change the locale is `localeOf(uri)` resolved against what you bundled (`fr-CA` becomes `fr`), else the
previous one, else `preferredLocale`. The scope also sets `Localizations.override`, so Material strings and the text
direction follow: an `ar` route is right to left.

**`localizationsDelegates: GlobalMaterialLocalizations.delegates` is required** (and `flutter_localizations` in the
pubspec). Without it, a route in a language the app has no `MaterialLocalizations` for makes an `AppBar` or a `BackButton`
throw "No MaterialLocalizations found". `supportedLocales` has no effect on the override, but keep it right for the
platform.

`localeSpelling(AppManifest.all)` and `relocate(..., routes: AppManifest.all)` read the generated route manifest
(`AppManifest`, written into `app.g.dart` or into the library `output_manifest` names): import the one that has it.

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
`other`, `offset:` and `#`), `select` and `'` quoting. Plural categories come from `intl`, so French treats 0 as `one`
and English `zero {..}` is not used for 0 (only `=0` is). `selectordinal` is **not supported** (`intl` has no ordinal
rules): such a message is shown as written, and reported once in debug. Tolgee's ARB export does not replace `#`, so it
repeats the placeholder (`{count, plural, one {{count} dog} other {{count} dogs}}`): both forms work.

Things that differ from what you may expect:

- **Apostrophes are ICU quotes.** `l''{app}` writes `l'` followed by the value, but `l'{app}` quotes the brace: it renders
  `l{app}`. Files written for `gen-l10n` (whose default is no escaping) may need their apostrophes before `{` or `}`
  doubled. A `'` that is not followed by `{`, `}` (or `#` in a plural) is a plain apostrophe.
- **Numbers are not locale-formatted.** `#`, `{n}` and `{n, number}` print the number as Dart does (`1000`, not `1 000`);
  format it yourself and pass the string if you need that.
- **Fractions** pick the plural category the way `intl` reads the number: in French, 1.5 is `other`.
- **A `select` given an enum** matches on its `name`.
- A malformed message is shown as written and reported once in debug.

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
- Only the locale a route uses is fetched (its resolved tag), not the language or base links of its chain: those
  answer from bundled text, or from the cache if that locale was fetched or cached before.
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

Edit a translation in the running app and see it at once. It is compiled in only when both hold: a debug build, and
`--dart-define=fespalier_tolgee.in_context=true` (`kTolgeeInContext` in `package:fespalier_tolgee/in_context.dart`).

```sh
flutter run --dart-define-from-file=tolgee.local.json
```

`tolgee.local.json` is gitignored and holds `{"fespalier_tolgee.in_context": "true", "TOLGEE_API_KEY": "tgpak_..."}`. Give
the key only the scopes you need (translations.edit). **Never pass the key to `flutter build`:** a key in a build is
public. Release builds pass only `TOLGEE_CDN_URL`; in release and profile builds `kTolgeeInContext` is a `const false` (and the scope's only other
condition is behind `kDebugMode`), so the panel, the editor and the key's `String.fromEnvironment` are compiled out.

A small handle opens a panel with the keys read on the current screen, their value and their origin. A save calls
`PUT /v2/projects/translations` with `X-API-Key` and puts the text into the edited layer at once, so you do not wait for
the CDN. Everyone else sees it when Tolgee publishes. Without a key the panel is read only.

## Testing

`pumpRouter`'s default app is a bare `MaterialApp.router`, with no scope, so pass your app: `app: (router) => App(router: router)`
(or the generated `AppMain.app`), the one that uses `TranslationScope.routerConfig`.

```dart
await pumpRouter(
  tester,
  AppRoutes.router(initialLocation: '/fr/products'),
  app: (router) => App(router: router),
  overrides: fakeTranslations(
    bundled: {'en': {'title': 'Products'}, 'fr': {'title': 'Produits'}},
    remote: FakeTranslations.strict(), // a key nobody has fails the test
  ),
);
```

- `FakeTranslations` is an in-memory source with no delay: `set(locale, messages)`, `offline()`, `notModified()`,
  `fetchCount(locale)`. A fetch lands on the next `pump`.
- A restart: share one `MemoryDataStorage` (`dataCacheStorage.overrideWithValue`) between two `pumpRouter` calls.
- `fsp test` and `test/routes/setup.dart` need the same two things: return `fakeTranslations(...)` from `overrides(pattern)`,
  and run the app's own `app` (a smoke test through the default app has no scope, and `context.tr` throws).
- `RecordingEditor` records what the in-context panel saves.

## Rules and what it costs

- Every read is synchronous and from memory; a translator is never an `AsyncValue`.
- No timer, no polling, no microtask, and no listener of its own (the Router's is forwarded to go_router's delegate):
  `test/no_timers_test.dart` greps `lib/`.
- No API key in a release build, and `TolgeeCdn` has no parameter for one: `test/no_secrets_test.dart` greps `lib/`.
- No telemetry in v1. A future `TelemetryOp` would go through `FespalierTelemetry.begin` and `finish` and never carry keys,
  texts or the CDN URL.
- It adds `http`, `intl` and `clock` (the cache's age is read from it, so a test's fake clock ages it) and nothing else
  beyond fespalier. It is in the Flutter 3.32 `floor` job.

## Not built

Typed keys (reading assets at build time is `gen-l10n`'s job, and `app.g.dart` must depend on `lib/app` and the pubspec
alone; an app may keep `gen-l10n` beside this, its getters are just not updated over the air), the `tolgee` SDK's widgets,
a polling refresh, and a `fespalier_adapter.dart` entry (the bundled texts are an async asset read and the setup is app
code, which `startup()` already does).
