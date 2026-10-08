import 'package:fespalier/fespalier.dart';
import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter/material.dart';
import 'package:i18n/app.g.dart';
import 'package:i18n/lang.dart';

/// Around every page of a language: an AppBar whose actions are the language switch. Asking for
/// `lang` here is also what types the `$lang` segment as the enum.
///
/// The switch is plain buttons, not a dropdown. Each one navigates to the same page spelled in
/// the other language (`/en/products` becomes `/fr/produits`): `relocate` rewrites the `$lang`
/// segment and each localized spelling, and keeps the query. It is `go`, not `push`, because it
/// is the same page.
class LangLayout extends StatelessWidget {
  const LangLayout({super.key, required this.lang, required this.child});

  final Lang lang;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final here = GoRouterState.of(context).uri;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('app.title')),
        actions: [
          for (final other in Lang.values)
            TextButton(
              key: ValueKey('switch-${other.name}'),
              onPressed: other == lang
                  ? null
                  : () => context.go(
                      relocate(
                        here,
                        to: other.name,
                        routes: AppManifest.all,
                        segment: 0,
                      ),
                    ),
              child: Text(other.name.toUpperCase()),
            ),
        ],
      ),
      body: child,
    );
  }
}
