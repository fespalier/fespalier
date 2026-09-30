import 'package:features/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// A sheet with a URL of its own: `present.dart` next to this file builds its
/// page (the app's `SheetPage`), and it is shown on the root navigator, above
/// the root layout, with `/photos` still built underneath.
class ShareSheet extends StatelessWidget {
  const ShareSheet({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Share photos'),
            TextButton(
              onPressed: () => const TermsRoute().push(context),
              child: const Text('Terms'),
            ),
            TextButton(
                onPressed: () => context.pop(), child: const Text('Done')),
          ],
        ),
      );
}
