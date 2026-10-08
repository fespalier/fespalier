import 'package:fespalier/startup.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:i18n/lang.dart';

/// Runs once, before the app, while splash.dart shows. It reads the catalogs bundled in
/// `assets/i18n/` (a local read, never the network), so the first frame is already translated.
///
/// This example has no `remote:`: nothing is fetched and no key exists. To get fresh texts over
/// the air, add `remote: TolgeeCdn(Uri.parse(cdnUrl))` here (the README says how).
Future<List<Override>> startup() async => [
  translationsConfig.overrideWithValue(
    Translations(
      bundled: await BundledTranslations.load(
        locales: Lang.values.map((lang) => lang.name),
      ),
      baseLocale: 'en',
    ),
  ),
];
