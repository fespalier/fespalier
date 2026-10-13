import 'package:fespalier/fespalier.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:i18n/app.g.dart';
import 'package:i18n/lang.dart';

/// `/` has no language: send the person to the device's, or to English when the app has none of
/// them. `preferredLocale` is the first supported locale of the device (a real app would override
/// the provider with the language the person saved).
String redirect(Ref ref) {
  final tag = ref.read(preferredLocale);
  final lang = Lang.values.where((lang) => lang.name == tag).firstOrNull;
  return HomeRoute(lang: lang ?? Lang.en).location;
}
