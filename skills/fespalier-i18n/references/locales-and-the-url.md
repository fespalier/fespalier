# The language in the URL

Since 0.10.0. The locale is part of the route, so a link, a refresh and a deep link all show the same language. Two
folder features give it to `TranslationScope.routerConfig`; use either or both. Nothing here needs a `fespalier:`
key: the package reads the folders you already have.

## A `$lang` segment

Make it an **enum**, so `/xx/products` is not found, and **ask for it** in some file of the folder (a `page.dart`, a
`data.dart`, a `guard.dart`): the generator types a segment from the parameters that ask for it, so without
`required Lang lang` somewhere `$lang` is a `String` and `/xx/products` matches (and `localeSegment()` then offers
`xx`, which the scope cannot resolve, so it keeps the previous locale).

```dart
// lib/lang.dart
enum Lang { en, fr, de }
```

```dart
// lib/app/$lang/products/page.dart
import 'package:flutter/material.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:my_app/lang.dart';

class ProductsPage extends StatelessWidget {
  const ProductsPage({super.key, required this.lang});

  final Lang lang;

  @override
  Widget build(BuildContext context) =>
      Scaffold(appBar: AppBar(title: const TrText('products.title')), body: Text(context.routeLocale));
}
```

- **Tags that are not identifiers** (`pt-BR`, `zh-Hant`) cannot be enum names. Use a `String` segment and let the scope
  resolve it: `fr-CA` becomes `fr`, `pt-BR` becomes `pt` if only `pt` is bundled, an unknown tag keeps the previous
  locale. A `String` segment accepts any text, so check it in a guard if `/xx/...` must be not found.
- `localeSegment({int at = 0})` reads the URL's segment `at` (0 is `/fr/products`'s `fr`). A `$lang` that is not the
  first folder passes its index.

## Localized spellings

A `route.dart` can spell its own segment per locale (`fespalier-routing`,
[`route-dart.md`](../../fespalier-routing/references/route-dart.md#localized-paths)). The scope reads them with
`localeSpelling(AppManifest.all)`: `/produits` says `fr`.

```dart
// lib/app/$lang/products/route.dart
// /fr/produits and /de/produkte; /fr/products still answers
const paths = {'fr': 'produits', 'de': 'produkte'};
```

- **Spellings alone say nothing about a canonical path** (`/products` fits every locale), **nor about a spelling two
  locales share**, nor about one that equals the canonical name: `localeSpelling` answers `null` for those, and the
  locale is then the previous one, or `preferredLocale` (the device's). Pair spellings with a `$lang` folder, or
  accept that.
- Use both: `localeOf: firstLocaleOf([localeSegment(), localeSpelling(AppManifest.all)])`; the first reader that
  answers wins. A `LocaleOfUri` is `String? Function(Uri uri)`, so a reader of your own (a subdomain, a query
  parameter) is one function.
- `AppManifest` is written into `app.g.dart` (or into the library `output_manifest` names): import the one that has
  it.

## How the locale is chosen

On each location change the scope takes `localeOf(uri)` and resolves it against what you **bundled**: an exact tag,
then its language (`fr-CA` to `fr`); if that gives nothing, **the previous locale**; before any, `preferredLocale`
(the device's first supported locale, else the base). The scope also sets `Localizations.override`, so Material
strings and the **text direction** follow: an `ar` route is right to left. `context.routeLocale` is the tag that won.

There is **no global locale** (`fespalier-routing` says so on purpose): a `data.dart` that needs the language takes it
as the typed segment, `required Lang lang`, and so is keyed by it.

## A language menu: `relocate`

`relocate(uri, to:, routes:, segment:)` respells the current location for another language and keeps the query: a
locale segment at `segment` is replaced, and each localized level goes through `RouteInfo.pathFor(to)`
(`/fr/produits/2?q=1` becomes `/de/produkte/2?q=1`). Navigate with `go`, not `push`: it is the same page in another
language.

```dart
// lib/language_menu.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart'; // AppManifest
import 'package:my_app/lang.dart';

class LanguageMenu extends StatelessWidget {
  const LanguageMenu({super.key});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final lang in Lang.values)
        TextButton(
          onPressed: () => context.go(
            relocate(
              GoRouterState.of(context).uri,
              to: lang.name,
              routes: AppManifest.all,
              segment: 0, // the $lang folder is the first segment; leave it out for spellings only
            ),
          ),
          child: Text(lang.name),
        ),
    ],
  );
}
```

Put the menu where `GoRouterState.of(context)` works: inside a page or a layout, not in `app.dart`'s own widget above
the router.

## The first URL

`/` has no language. Make the root folder's `redirect.dart` send people to their own, using `preferredLocale` (the
device's first supported locale; override the provider with the user's own saved choice). The sample is a `/start`
folder so it builds beside the example's root `page.dart`; at the app root it is `lib/app/redirect.dart` and a
folder has a `page.dart` **or** a `redirect.dart`, not both (see
[`fespalier-guards`](../../fespalier-guards/references/guards-and-redirects.md)).

```dart
// lib/app/start/redirect.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/lang.dart';

String redirect(Ref ref) => ProductsRoute(lang: Lang.values.byName(ref.read(preferredLocale))).location;
```

`Lang.values.byName(...)` throws for a tag that is not an enum name (`pt-BR`): with a `String` segment pass the tag
as it is.

## Where the code is

`packages/fespalier_tolgee/lib/src/locale.dart` (`localeSegment`, `firstLocaleOf`, `localeSpelling`, `relocate`,
`localeFromTag`) and `scope.dart` (`TranslationScope.routerConfig`, which builds the scope inside the Router's own
build). One config is made per router, so make the router once (`AppRoutes.router()` at startup, as the generated
`main()` does).
