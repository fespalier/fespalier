# Messages and catalogs

Since 0.10.0. A catalog is one language's `key to message` map; a message is the **ARB subset of ICU**. The same
messages serve the bundled files and Tolgee's Content Delivery.

## The files

One file per language under `assets/i18n/` (list the folder under `flutter: assets:`), read by
`BundledTranslations.load(locales: [...])` from `rootBundle`: `assets/i18n/{locale}.arb` by default; `path:` changes
the pattern (`'assets/i18n/{locale}.json'`).

| Format                                          | When                                                                                                                 |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| ARB (a path ending in `.arb`)                   | `@key` and `@@locale` entries are skipped, every other string entry is a message                                     |
| Tolgee JSON (anything else), **nested or flat** | nested objects become dotted keys (`cart.title`); numbers and booleans keep their text; `null` and lists are skipped |

```json
// assets/i18n/fr.arb
{
  "@@locale": "fr",
  "product.title": "{name}",
  "product.stock": "{count, plural, =0 {Épuisé} one {# en stock} other {# en stock}}"
}
```

A file that is not a JSON object throws `FormatException: A catalog is a JSON object` from `startup()`, and so
does a missing asset; `splash.dart` then offers the retry. A local read, never the network.

Fill the folder with Tolgee's own CLI (`tolgee pull`) or a manual export, optionally as a `before:` step of a `tasks:`
entry (read by `fsp dev`, `fsp build` and `fsp run`, since 0.9.0;
[`fespalier`](../../fespalier/references/cli-and-config.md) has the schema):

```yaml
# pubspec.yaml (a fragment: the tolgee CLI is yours to install and configure)
fespalier:
  tasks:
    dev:
      before: tolgee pull
```

Commit the pulled files: they are the offline floor, and a build that cannot reach Tolgee must still have them.

## What a message can say

`{name}`, `plural` (with `=0`, `zero`, `one`, `two`, `few`, `many`, `other`, `offset:` and `#`), `select`, and `'`
quoting. `other` is required in a plural and a select. Tolgee's ARB export does not replace `#`, so it repeats the
placeholder (`{count, plural, one {{count} dog} other {{count} dogs}}`): both forms work.

What differs from what you may expect:

- **Apostrophes are ICU quotes.** `l''{app}` writes `l'` followed by the value, but `l'{app}` quotes the brace and
  renders `l{app}`. A `'` not followed by `{`, `}` (or `#` in a plural) is a plain apostrophe.
- **Plural categories come from `intl`**, not from your language list: French treats 0 as `one`, English `zero {..}`
  is never used for 0 (only `=0` is), and a fraction picks the category `intl` reads (in French 1.5 is `other`).
- **Numbers are not locale-formatted.** `#`, `{n}` and `{n, number}` print the number as Dart does (`1000`); format
  it yourself and pass the string.
- **`selectordinal` is not supported** (`intl` has no ordinal rules): the message is shown as written, and reported
  once in debug.
- **A `select` given an enum** matches on its `name`.
- **A malformed message is shown as written** and reported once per key in debug, through `FlutterError.reportError`
  (library `fespalier_tolgee`, "while formatting a translation"), so a `testWidgets` fails on it. The messages are in
  [`diagnostics-tolgee.md`](../../fespalier-troubleshooting/references/diagnostics-tolgee.md).
- `tr` never throws: a key nobody has is returned as itself (and `Translations(onMissing:)` hears it; the test helpers
  use that to fail on a typo).

## Keeping `gen-l10n` beside it, or leaving it

- **Beside it.** The package does not read `l10n.yaml` or generate getters. An app may keep `gen-l10n` for typed keys:
  those getters just are not updated over the air, and the two do not share files unless you point both at the same
  `.arb`. Keep `GlobalMaterialLocalizations.delegates` in `localizationsDelegates` and add `AppLocalizations.delegate`
  next to them: the scope needs the Material ones.
- **Moving from `gen-l10n`.** Keys become strings (`context.tr('home.title')`), `{count, plural, ...}` works as it
  did. Files written for `gen-l10n` (whose default is no escaping) may need their apostrophes before `{` or `}`
  doubled, and a placeholder's type (`int`, `DateTime`, `@key` metadata) is no longer read: pass the values, formatted
  if need be.
- **Moving from the `tolgee` SDK.** `Tolgee.tr(...)` becomes `context.tr(...)`, `Tolgee.setCurrentLocale` becomes a
  navigation (`relocate`), `Tolgee.init(cdnUrl:, apiKey:)` becomes the `Translations` in `startup()` with a
  `TolgeeCdn` that takes **no key**. Its in-context mode is the debug-only panel
  ([`in-context-editing.md`](in-context-editing.md)).

## Where the code is

`packages/fespalier_tolgee/lib/src/catalog.dart` (the two readers), `icu.dart` (the parser and its error messages),
`translator.dart` (the chain, `tr`, `maybeTr`, `messageOf`) and `bundled.dart`.
