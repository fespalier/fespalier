import 'package:fespalier/startup.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:http/http.dart' as http;
import 'package:i18n/lang.dart';

/// The public Content Delivery URL of a Tolgee project (`--dart-define=TOLGEE_CDN_URL=...`). Empty:
/// no over-the-air texts, only the bundled ones, and no request is ever made.
const String cdnUrl = String.fromEnvironment('TOLGEE_CDN_URL');

/// Runs once, before the app, while splash.dart shows. It reads the catalogs bundled in
/// `assets/i18n/` (a local read, never the network), so the first frame is already translated.
///
/// The app's one transport is built here and handed to every package that sends: `TolgeeCdn` fetches
/// the fresh texts through it. With no `TOLGEE_CDN_URL` there is no `remote:`: nothing is fetched and
/// no key exists (the CDN takes none).
Future<List<Override>> startup() async {
  // In your app: the same transport goes to fespalier_auth, fespalier_download and the others.
  final transport = HttpClientTransport(http.Client());
  return [
    translationsConfig.overrideWithValue(
      Translations(
        bundled: await BundledTranslations.load(
          locales: Lang.values.map((lang) => lang.name),
        ),
        baseLocale: 'en',
        remote: cdnUrl.isEmpty
            ? null
            : TolgeeCdn(Uri.parse(cdnUrl), transport: transport),
      ),
    ),
  ];
}
