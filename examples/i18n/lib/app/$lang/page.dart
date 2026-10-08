import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter/material.dart';
import 'package:i18n/app.g.dart';
import 'package:i18n/lang.dart';

/// `/en`, `/fr`. The texts are keys: `TrText` and `context.tr` look them up in the language of the
/// route.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.lang});

  final Lang lang;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const TrText('home.title', style: TextStyle(fontSize: 32)),
      const TrText('home.intro'),
      // Only en.arb has this key: in French it falls back to the English text, not to the key.
      const TrText('home.footer'),
      TextButton(
        onPressed: () => ProductsRoute(lang: lang).go(context),
        child: Text(context.tr('home.products')),
      ),
    ],
  );
}
