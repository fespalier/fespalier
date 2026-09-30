import 'package:features/app.g.dart';
import 'package:features/page_meta.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// Layouts read the query too: `/?banner=hello`.
///
/// They can also read the route manifest: the browser tab title (and the
/// app-switcher label) comes from the page's `meta.dart`, when it has one.
class RootLayout extends StatelessWidget {
  const RootLayout({super.key, required this.child, this.banner});

  final Widget child;
  final String? banner;

  @override
  Widget build(BuildContext context) {
    final info = AppManifest.of(GoRouterState.of(context));
    return Title(
      title: info?.metaAs<PageMeta>()?.title ?? 'Features',
      color: Colors.blue,
      child: Scaffold(
        body: Column(
          children: [
            if (banner != null) Text('Banner: $banner'),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
