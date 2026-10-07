/// Translations for fespalier (since 0.10.0): bundled catalogs that show on the first frame and
/// offline, Tolgee's Content Delivery (or any `TranslationSource`) over the air, a cache in
/// fespalier's `dataCacheStorage`, and the locale of the route (`$lang` segments and `paths`
/// spellings) provided inside the Router by `TranslationScope.routerConfig`.
///
/// Every read is synchronous and from memory; nothing here starts a timer or polls. It does not
/// depend on the `tolgee` SDK. In-context editing is `package:fespalier_tolgee/in_context.dart`,
/// compiled in only with `--dart-define=fespalier_tolgee.in_context=true` in a debug build.
library;

export 'src/bundled.dart' show BundledTranslations;
export 'src/catalog.dart' show Catalog;
export 'src/locale.dart'
    show
        LocaleOfUri,
        firstLocaleOf,
        localeFromTag,
        localeSegment,
        localeSpelling,
        relocate;
export 'src/providers.dart'
    show preferredLocale, translationsConfig, translator;
export 'src/scope.dart' show TranslateContext, TranslationScope, TrText;
export 'src/source.dart' show RemoteCatalog, TranslationSource;
export 'src/tolgee_cdn.dart' show TolgeeCdn, TolgeeCdnFormat;
export 'src/translations.dart' show Translations;
export 'src/translator.dart'
    show TranslationOrigin, Translator, TranslatorLayer;
