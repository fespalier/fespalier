# Over the air, the cache and the fallback chain

Since 0.10.0. Fresh texts are an **addition** to the bundled ones, never a requirement: a first launch offline shows
bundled text, with no error and no pending timer.

## Tolgee's Content Delivery

Create a Content Delivery in Tolgee (Project settings), pick **JSON** or **ARB**, flat or nested, and copy its URL (it
is public, not a secret).

```dart
// lib/app/startup.dart
import 'package:fespalier/fespalier.dart' show dataCacheStorage;
import 'package:fespalier/startup.dart';
import 'package:fespalier_storage/fespalier_storage.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';

const _cdn = String.fromEnvironment('TOLGEE_CDN_URL');

Future<List<Override>> startup() async => [
  translationsConfig.overrideWithValue(
    Translations(
      bundled: await BundledTranslations.load(locales: ['en', 'fr']),
      baseLocale: 'en',
      remote: _cdn.isEmpty
          ? null
          : TolgeeCdn(Uri.parse(_cdn), format: TolgeeCdnFormat.arb, namespace: 'app'),
      refreshOnResume: true, // off by default
      cacheMaxAge: const Duration(days: 7), // 30 days by default
    ),
  ),
  // The cache of fetched catalogs: without a storage they live only in memory.
  dataCacheStorage.overrideWithValue(await PrefsDataStorage.open()),
];
```

`TolgeeCdn(base, {format = TolgeeCdnFormat.json, namespace, file})` asks for `<base>/<locale>.json` (`.arb` for the ARB
format), or `<base>/<namespace>/<locale>.json`; `file: (locale) => ...` overrides the file name. It has **no parameter
for an API key**, by design: a key in a build is public.

- **ETag.** The first answer's `ETag` is saved; the next ask sends `If-None-Match`. A **304 or a 404 changes nothing**,
  and any other failure (a `5xx`, no network, a body that is not a JSON object) keeps what the app has, **silently**:
  nothing is printed, nothing throws. The fetcher swallows every error. `Translator.originOf(key)` is how a test or a
  debug screen finds out which link answered.
- **What is fetched.** Only the locale a route uses (its resolved tag, `fr-CA` if you bundled `fr-CA`), not the
  language or base links of its chain: those answer from bundled text, or from the cache if that locale was fetched or
  cached before. A locale is fetched **once per `ProviderContainer`**; it is asked again only on a refresh signal.
- **Never on a timer.** `refreshOnResume: true` asks again when the app resumes (fespalier's `appResumeSignal`);
  `refreshOnReconnect` (on by default) asks once the network is back **after a failed fetch**, through
  `reconnectSignal`, which does nothing until the app overrides it with `ConnectivitySignal.new`
  ([`fespalier-data`](../../fespalier-data/references/reconnect-and-network.md)). `autoSync` of
  `fespalier_cratestack` consumes the same signal.
- **Tolgee publishes after a change with a delay of up to 15 minutes**, so a text edited just now is not on the CDN
  yet, and a person who sees the old text for a while has not hit a bug.
- **The web needs the CDN to answer with CORS headers.** If it does not, a web app keeps working on bundled and cached
  texts, and nothing says why: the browser's console does.

## The chain, and the cache

A key is looked up in this order, and the first catalog that has it wins:

1. edited in the in-context panel (debug builds only),
2. the remote catalog fetched in this run, or the cached one,
3. the bundled one,

each for the locale (`fr-CA`), then its language (`fr`), then the base locale, then the key itself.
`translator.originOf(key)` answers a `TranslationOrigin`: `edited`, `remote`, `cached`, `bundled`, `fallbackLocale`
(found under the language or the base) or `missing` (the key is shown).

Remote catalogs are saved in fespalier's `dataCacheStorage` under **`fespalier_tolgee:<tag>`** for `cacheMaxAge`:

- A synchronous storage (`fespalier_storage`'s `PrefsDataStorage`) has them on the **first frame**; Hive's arrives a
  frame later, so the very first paint may be bundled text.
- The storage's size budget may evict an entry written long ago. That is harmless: the chain falls back to the bundled
  text, and the next fetch saves it again. The entries share the budget with `dataCache` values.
- A cache that cannot be written is only a cache: the error is swallowed.
- The age is read from `package:clock`, so a test's fake clock ages it.

## Your own `TranslationSource`

Anything that can answer `fetch(locale, {etag})` is a source: your own server, a file store, a fake.

```dart
// lib/api_translations.dart
import 'package:fespalier_tolgee/fespalier_tolgee.dart';

/// What the app's own API answers: the JSON text and an ETag, or null for "unchanged" and "none".
typedef TranslationAnswer = ({String body, String? etag});

class ApiTranslations implements TranslationSource {
  ApiTranslations(this._ask);

  final Future<TranslationAnswer?> Function(String locale, String? etag) _ask;

  @override
  Future<RemoteCatalog?> fetch(String locale, {String? etag}) async {
    final answer = await _ask(locale, etag);
    if (answer == null) return null; // a 304, or nothing for this locale: the app keeps what it has
    return RemoteCatalog(Catalog.fromJson(locale, answer.body), etag: answer.etag);
  }
}
```

The rules for a source: **null means "nothing new"**, a **throw means "failed"** (the app keeps what it has, and
`refreshOnReconnect` may ask again), and it is asked at most once per locale per container plus the refresh signals.
Never block on a timer inside it.

## Where the code is

`packages/fespalier_tolgee/lib/src/providers.dart` (the fetcher, the cache key and the write), `tolgee_cdn.dart`,
`source.dart`, `translator.dart` (`TranslationOrigin`, `originOf`) and `translations.dart` (`resolve`, the refresh
flags).
