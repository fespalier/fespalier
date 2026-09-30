import 'package:flutter/material.dart';

/// Layouts read the query too: `/?banner=hello`.
class RootLayout extends StatelessWidget {
  const RootLayout({super.key, required this.child, this.banner});

  final Widget child;
  final String? banner;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(
          children: [
            if (banner != null) Text('Banner: $banner'),
            Expanded(child: child),
          ],
        ),
      );
}
