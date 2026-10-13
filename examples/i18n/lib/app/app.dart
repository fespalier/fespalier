import 'package:fespalier/fespalier.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// The app around the router.
///
/// `routerConfig` is the scope's, never the router itself: the config puts a TranslationScope
/// around go_router's navigator, so the first frame is already in the language of the URL.
/// `localeSegment()` reads it from the first segment (`/fr/...`). The Material delegates are
/// required: without them an AppBar in a language Material has no strings for throws.
class App extends ConsumerWidget {
  const App({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: 'Translations',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    routerConfig: TranslationScope.routerConfig(
      router,
      localeOf: localeSegment(),
    ),
    supportedLocales: ref
        .watch(translationsConfig)
        .supportedLocales
        .map(localeFromTag),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
  );
}
